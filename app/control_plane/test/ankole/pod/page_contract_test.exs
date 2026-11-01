defmodule Ankole.Pod.PageContractTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ecto.Query, only: [from: 2]
  alias Ankole.Pod.{Documents, Page, PageChange, PageContent, Pages}

  setup do
    owner = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "agent:#{agent.uid}",
        action: "chat"
      })

    %{owner: owner, agent: agent}
  end

  test "purge batches select leaves before limiting a large subtree", ctx do
    {:ok, root} = Pages.create(actor_fixture(ctx.owner.uid), %{type: "folder"})
    now = DateTime.utc_now(:microsecond)

    parents =
      for n <- 1..1001 do
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: ctx.owner.tenant_id,
          type: :folder,
          title: "Parent #{n}",
          position: Integer.to_string(n),
          parent_id: root.id,
          acl_anchor_id: root.acl_anchor_id,
          created_by: root.created_by,
          created_at: now,
          updated_at: now
        }
      end

    children =
      Enum.map(parents, fn parent ->
        %{parent | id: Ankole.Ecto.UUIDv7.autogenerate(), parent_id: parent.id, title: "Leaf"}
      end)

    insert_page_rows(parents)
    insert_page_rows(children)
    ids = Enum.map(parents ++ children, & &1.id)

    assert {:ok, 1000} =
             Repo.transact_top_level(fn ->
               Ankole.Files.Jobs.PurgeNode.remove_nodes_in_tx(ids)
             end)

    assert Repo.aggregate(from(p in Page, where: p.id in ^ids), :count) == 1002
  end

  test "a new blank page is editable and retransmission applies each OT batch once", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    assert page.title == ""
    assert Repo.get!(PageContent, page.id).content == "<page />"

    batch = %{
      base_revision: 0,
      client_id: "browser",
      client_seq: 1,
      changes: [
        [1, [%{"remove" => "PagePlaceholder", "value" => nil}]],
        [0, [%{"type" => "Text", "param" => "Hello"}]],
        1
      ]
    }

    assert {:ok, %{revision: 1, acknowledged_revision: 1}} =
             Documents.apply(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               batch
             )

    assert {:ok, %{revision: 1, acknowledged_revision: 1}} =
             Documents.apply(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               batch
             )

    assert Repo.get!(PageContent, page.id).content == "<page><p>Hello</p></page>"
    assert Repo.aggregate(PageChange, :count) == 1

    assert {:ok, %{revision: 1, changes: [%{client_seq: 1}]}} =
             Documents.apply(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               batch
               | client_seq: 2
             })

    assert Repo.get!(Page, page.id).revision == 1
  end

  test "a reused client sequence with another payload rejects the new edit", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    batch = %{
      base_revision: 0,
      client_id: "editor",
      client_seq: 1,
      changes: [
        [1, [%{"remove" => "PagePlaceholder", "value" => nil}]],
        [0, [%{"type" => "Text", "param" => "Original"}]],
        1
      ]
    }

    assert {:ok, %{revision: 1}} =
             Documents.apply(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               batch
             )

    assert {:error, :client_sequence_conflict} =
             Documents.apply(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               batch
               | changes: [[0, [%{"type" => "Text", "param" => "Different"}]], 1]
             })

    assert Repo.get!(PageContent, page.id).content == "<page><p>Original</p></page>"
  end

  test "replay asks for a snapshot before loading a log larger than the socket message budget",
       ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    now = DateTime.utc_now(:microsecond)
    author = Ankole.ActorRef.from_principal(ctx.owner)
    # Each stored batch fits the message budget; their replay together does not.
    changes = [[0, [%{"type" => "Text", "param" => String.duplicate("中", 6_000_000)}]], 1]

    for revision <- 1..2 do
      assert {:ok, _} =
               {:ok,
                Ankole.Pod.PagesFixtures.create_record!(PageChange, :append, %{
                  page_id: page.id,
                  revision: revision,
                  kind: :change,
                  client_id: "editor",
                  client_seq: revision,
                  changes: changes,
                  author: author,
                  created_at: now
                })}
    end

    Ankole.Pod.PagesFixtures.update_record!(
      Ankole.Pod.PagesFixtures.update_record!(page, :advance_revision, %{
        updated_at: DateTime.utc_now(:microsecond)
      }),
      :advance_revision,
      %{updated_at: DateTime.utc_now(:microsecond)}
    )

    assert {:ok, %{revision: 2, changes: [], reset_required: true, reload_required: true}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 0)

    assert {:ok, %{revision: 2, changes: [_], reset_required: false}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 1)
  end

  test "an Agent change is visible to stale clients and rejected Agent writes leave content intact",
       ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
      })

    assert {:ok, %{page: %{revision: 1}}} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               page.id,
               0,
               "<page><p>Agent</p></page>"
             )

    assert {:error, {:revision_conflict, 1}} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               page.id,
               0,
               "<page />"
             )

    assert {:error, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               page.id,
               1,
               "<page><p><table /></p></page>"
             )

    assert Repo.get!(PageContent, page.id).content == "<page><p>Agent</p></page>"

    assert {:ok, %{changes: [%{kind: :change}], reset_required: false}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 0)

    Repo.delete_all(PageChange)

    assert {:ok, %{changes: [], reset_required: true}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 0)

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{grants: []})

    assert {:error, :forbidden} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), page.id, 0)

    assert {:error, :forbidden} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               page.id,
               1,
               "<page />"
             )
  end

  test "trash retention defaults to 30 days and is checked again when a job runs", ctx do
    assert {:ok, 30} = Ankole.AppConfigure.get_by_key("drive.trash_retention_days")
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id)

    assert_enqueued(
      worker: Ankole.Files.Jobs.PurgeNode,
      args: %{node_id: page.id, tenant_id: Repo.tenant_id!()}
    )

    assert {:snooze, seconds} =
             Ankole.Files.Jobs.PurgeNode.perform(%Oban.Job{
               args: %{"tenant_id" => Repo.tenant_id!(), "node_id" => page.id}
             })

    assert seconds > 29 * 86_400
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("drive.trash_retention_days", 60)

    assert {:snooze, longer} =
             Ankole.Files.Jobs.PurgeNode.perform(%Oban.Job{
               args: %{"tenant_id" => Repo.tenant_id!(), "node_id" => page.id}
             })

    assert longer > 59 * 86_400
    assert is_nil(Repo.get!(Page, page.id).purge_started_at)
  end

  test "zero trash retention keeps deleted pages and purges them once a retention is set again",
       ctx do
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("drive.trash_retention_days", 0)
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid)
    {:ok, page} = Pages.create(actor, %{})
    {:ok, _} = Pages.delete(actor, page.id)

    assert_enqueued(
      worker: Ankole.Files.Jobs.PurgeNode,
      args: %{node_id: page.id, tenant_id: Repo.tenant_id!()}
    )

    long_ago = DateTime.add(DateTime.utc_now(:microsecond), -400 * 86_400, :second)

    Repo.update_all(from(n in Ankole.Files.Schemas.Node, where: n.id == ^page.id),
      set: [deleted_at: long_ago]
    )

    job = %Oban.Job{args: %{"tenant_id" => Repo.tenant_id!(), "node_id" => page.id}}

    assert {:snooze, 86_400} = Ankole.Files.Jobs.PurgeNode.perform(job)
    assert is_nil(Repo.get!(Page, page.id).purge_started_at)

    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("drive.trash_retention_days", 30)
    assert :ok = Ankole.Files.Jobs.PurgeNode.perform(job)
    assert is_nil(Repo.get(Page, page.id))
  end

  test "OT replay retains its configured window and a pruned acknowledged retry never applies again",
       ctx do
    assert {:ok, 1000} = Ankole.Pod.Config.ot_replay_window()
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.ot_replay_window", 3)
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    batch = %{
      base_revision: 0,
      client_id: "lost-acknowledgement",
      client_seq: 1,
      changes: [
        [1, [%{"remove" => "PagePlaceholder", "value" => nil}]],
        [0, [%{"type" => "Text", "param" => "Hello"}]],
        1
      ]
    }

    assert {:ok, %{revision: 1, acknowledged_revision: 1}} =
             Documents.apply(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               batch
             )

    for revision <- 1..2,
        do:
          assert(
            {:ok, _} =
              Documents.write(
                Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
                page.id,
                revision,
                "<page><p>latest #{revision}</p></page>"
              )
          )

    assert {:ok, %{revision: 3, acknowledged_revision: 1, reset_required: false}} =
             Documents.apply(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               batch
             )

    assert {:ok, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               3,
               "<page><p>newer</p></page>"
             )

    assert {:ok, %{revision: 5, acknowledged_revision: 5}} =
             Documents.apply(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               base_revision: 4,
               client_id: "current-editor",
               client_seq: 1,
               changes: [6, [0, [%{"type" => "Text", "param" => "!"}]], 1]
             })

    assert Repo.aggregate(PageChange, :count) == 3

    assert {:ok,
            %{changes: [%{revision: 3}, %{revision: 4}, %{revision: 5}], reset_required: false}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 2)

    assert {:ok, %{reset_required: true}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 1)

    assert {:ok, %{reset_required: true}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 0)

    assert {:ok, %{revision: 5, reset_required: true} = retry} =
             Documents.apply(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               batch
             )

    refute Map.has_key?(retry, :acknowledged_revision)
    assert Repo.get!(Page, page.id).revision == 5
    assert Repo.get!(PageContent, page.id).content == "<page><p>newer!</p></page>"
    assert Repo.aggregate(PageChange, :count) == 3
  end

  test "direct and group roles take the highest permission and stop at a restricted boundary",
       ctx do
    {:ok, root} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: root.id})

    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{name: "page-editors", display_name: "Editors"})

    {:ok, _} = Ankole.AuthZ.add_principal_to_group(ctx.agent.uid, group.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, root.id, %{
        grants: [
          %{principal_uid: ctx.agent.uid, role: "view"},
          %{group_id: group.id, role: "edit"}
        ]
      })

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               child.id,
               "node_edit"
             )

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               child.id,
               "node_manage"
             )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{inherit_permissions: false})

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               child.id,
               "node_view"
             )

    assert {:ok, visible} = Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid))
    assert Enum.map(visible, & &1.id) == [root.id]
  end

  test "a saved source distinguishes deleted conversations from inaccessible conversations",
       ctx do
    attrs = %{
      conversation_id: Ankole.Kernel.gen_uuid_v7(),
      agent_uid: ctx.agent.uid,
      message_id: Ankole.Kernel.gen_uuid_v7(),
      text: "Research source"
    }

    {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.owner.uid, attrs)

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        saved_from_message_id: attrs.message_id
      })

    assert {:ok, %{source_conversation: %{id: source, deleted: false}}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id)

    assert source == detail.conversation.id

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
      })

    assert {:ok, generated} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), %{
               parent_id: page.id,
               saved_from_message_id: attrs.message_id
             })

    assert {:ok, %{source_conversation: %{id: ^source}}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), generated.id)

    outsider = human_fixture().principal

    assert {:ok, %{source_conversation: nil}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(outsider.uid), page.id)

    event = Repo.get_by!(Ankole.Signals.Signal, conversation_id: detail.conversation.id)

    assert {:error, :conversation_busy} =
             Ankole.Conversations.delete(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               detail.conversation.id
             )

    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Sessions.Queue.mark_event_completed_in_tx(
                 event,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert {:ok, _} =
             Ankole.Conversations.delete(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               detail.conversation.id
             )

    assert {:ok, %{source_conversation: %{deleted: true}}} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id)

    assert Repo.get(Page, page.id)
  end

  test "navigation bootstraps roots and only the active path with one authorization snapshot",
       ctx do
    actor = actor_fixture(ctx.owner.uid)
    {:ok, root} = Pages.create(actor, %{title: "Root"})
    {:ok, middle} = Pages.create(actor, %{parent_id: root.id, title: "Middle"})
    {:ok, active} = Pages.create(actor, %{parent_id: middle.id, title: "Active"})
    {:ok, sibling} = Pages.create(actor, %{title: "Unrelated"})
    {:ok, _} = Pages.create(actor, %{parent_id: sibling.id})
    handler = "navigation-snapshot-#{root.id}"

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, metadata, pid ->
        if self() == pid and String.contains?(metadata.query, "WITH execution AS"),
          do: send(pid, :navigation_snapshot)
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, result} = Pages.navigation(actor, active.id)
    assert Enum.map(result.path, & &1.id) == [root.id, middle.id, active.id]
    assert Enum.map(result.directories, & &1.parent_id) == [nil, nil, root.id, middle.id]
    assert_receive :navigation_snapshot
    refute_receive :navigation_snapshot
    assert Enum.all?(result.directories, &is_boolean(&1.can_manage_space))
  end

  test "directory branches count only live, visible direct children", ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = human_fixture().principal
    reader_actor = actor_fixture(reader.uid)
    {:ok, root} = Pages.create(owner, %{title: "Shared root"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, root.id, %{
        grants: [%{principal_uid: reader.uid, role: "view"}]
      })

    {:ok, hidden} = Pages.create(owner, %{parent_id: root.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, hidden.id, %{
        inherit_permissions: false,
        grants: []
      })

    {:ok, grandchild} = Pages.create(owner, %{parent_id: hidden.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, grandchild.id, %{
        grants: [%{principal_uid: reader.uid, role: "view"}]
      })

    assert {:ok, %{pages: [owner_root]}} = Pages.list_children(owner, nil)
    assert owner_root.aggregates.has_children
    assert {:ok, %{pages: [reader_root]}} = Pages.list_children(reader_actor, nil)
    refute reader_root.aggregates.has_children
    assert {:ok, %{pages: []}} = Pages.list_children(reader_actor, root.id)

    {:ok, visible} = Pages.create(owner, %{parent_id: root.id})
    assert {:ok, %{pages: [reader_root]}} = Pages.list_children(reader_actor, nil)
    assert reader_root.aggregates.has_children
    assert {:ok, %{pages: [leaf]}} = Pages.list_children(reader_actor, root.id)
    assert leaf.id == visible.id
    refute leaf.aggregates.has_children

    {:ok, _} = Pages.delete(owner, visible.id)
    assert {:ok, %{pages: [reader_root]}} = Pages.list_children(reader_actor, nil)
    refute reader_root.aggregates.has_children

    {:ok, _} = Pages.restore(owner, visible.id)
    assert {:ok, %{pages: [reader_root]}} = Pages.list_children(reader_actor, nil)
    assert reader_root.aggregates.has_children

    {:ok, _} = Pages.move(owner, visible.id, %{parent_id: hidden.id})
    assert {:ok, %{pages: [reader_root]}} = Pages.list_children(reader_actor, nil)
    refute reader_root.aggregates.has_children
  end

  test "navigation includes the active path beyond the first directory page", ctx do
    actor = actor_fixture(ctx.owner.uid)
    {:ok, root} = Pages.create(actor, %{title: "Root"})
    {:ok, active} = Pages.create(actor, %{parent_id: root.id, position: "z", title: "Active"})
    now = DateTime.utc_now(:microsecond)

    insert_page_rows(
      for n <- 1..200 do
        %{
          id: Ankole.Ecto.UUIDv7.autogenerate(),
          tenant_id: root.tenant_id,
          type: :file,
          title: "Sibling #{n}",
          position: "A" <> String.pad_leading(to_string(n), 3, "0"),
          parent_id: root.id,
          acl_anchor_id: root.acl_anchor_id,
          created_by: root.created_by,
          created_at: now,
          updated_at: now
        }
      end
    )

    assert {:ok, result} = Pages.navigation(actor, active.id)
    directory = Enum.find(result.directories, &(&1.parent_id == root.id))
    assert length(directory.pages) == 200
    refute Enum.any?(directory.pages, &(&1.id == active.id))
    assert Enum.map(result.path, & &1.id) == [root.id, active.id]

    assert {:ok, %{pages: [last]}} =
             Pages.list_children(actor, root.id, %{cursor: directory.next_cursor})

    assert last.id == active.id
  end

  test "branch existence and bootstrap paths follow the executing subject", ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = human_fixture().principal
    agent = actor_fixture(ctx.agent.uid)
    interactive = actor_fixture(reader)
    {:ok, root} = Pages.create(owner, %{})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, root.id, %{
        grants: [
          %{principal_uid: ctx.agent.uid, role: "view"},
          %{principal_uid: reader.uid, role: "view"}
        ]
      })

    {:ok, child} = Pages.create(owner, %{parent_id: root.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    assert {:ok, %{pages: [agent_root]}} = Pages.list_children(agent, nil)
    assert agent_root.aggregates.has_children
    assert {:ok, %{pages: [interactive_root]}} = Pages.list_children(interactive, nil)
    refute interactive_root.aggregates.has_children
    assert {:ok, %{path: []}} = Pages.navigation(interactive, child.id)
    assert {:ok, %{pages: []}} = Pages.list_children(interactive, root.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        grants: [
          %{principal_uid: ctx.agent.uid, role: "view"},
          %{principal_uid: reader.uid, role: "view"}
        ]
      })

    assert {:ok, %{pages: [interactive_root]}} = Pages.list_children(interactive, nil)
    assert interactive_root.aggregates.has_children
    assert {:ok, result} = Pages.navigation(interactive, child.id)
    assert Enum.map(result.path, & &1.id) == [root.id, child.id]
  end

  test "directory pagination uses bytewise C ordering and returns one covered projection" do
    principal = Ankole.PrincipalsFixtures.human_fixture().principal
    actor = Ankole.AuthZ.Actor.new(principal)

    for position <- ["A0", "a0", "Z0", "z0", "B0"] do
      assert {:ok, _} = Ankole.Pod.Pages.create(actor, %{title: position, position: position})
    end

    assert {:ok, first} = Ankole.Pod.Pages.list_children(actor, nil, %{limit: 2})
    assert Enum.map(first.pages, & &1.position) == ["A0", "B0"]

    assert {:ok, second} =
             Ankole.Pod.Pages.list_children(actor, nil, %{limit: 2, cursor: first.next_cursor})

    assert Enum.map(second.pages, & &1.position) == ["Z0", "a0"]

    assert {:ok, third} =
             Ankole.Pod.Pages.list_children(actor, nil, %{limit: 2, cursor: second.next_cursor})

    assert Enum.map(third.pages, & &1.position) == ["z0"]
    assert third.next_cursor == nil
    assert Enum.all?(first.pages ++ second.pages ++ third.pages, &(&1.role == "manage"))
  end

  test "directory pagination ends on exact full and empty pages" do
    principal = Ankole.PrincipalsFixtures.human_fixture().principal
    actor = Ankole.AuthZ.Actor.new(principal)

    pages =
      for position <- ["A0", "B0", "C0", "D0"] do
        assert {:ok, page} =
                 Ankole.Pod.Pages.create(actor, %{title: position, position: position})

        page
      end

    assert {:ok, first} = Ankole.Pod.Pages.list_children(actor, nil, %{limit: 2})
    assert Enum.map(first.pages, & &1.position) == ["A0", "B0"]
    assert is_binary(first.next_cursor)

    assert {:ok, second} =
             Ankole.Pod.Pages.list_children(actor, nil, %{limit: 2, cursor: first.next_cursor})

    assert Enum.map(second.pages, & &1.position) == ["C0", "D0"]
    assert second.next_cursor == nil

    assert {:ok, empty} =
             Ankole.Pod.Pages.list_children(actor, hd(pages).id, %{limit: 2})

    assert empty.pages == []
    assert empty.next_cursor == nil
  end

  defp insert_page_rows(rows) do
    {:ok, :inserted} =
      Repo.transact(fn ->
        nodes =
          Enum.map(rows, fn row ->
            row
            |> Map.drop([:type, :title, :position])
            |> Map.put(:kind, row.type)
            |> Map.put(:name, row.title)
          end)

        properties =
          Enum.map(
            rows,
            &Map.take(&1, [:tenant_id, :id, :title, :position, :created_at, :updated_at])
          )

        Repo.insert_all(Ankole.Files.Schemas.Node, nodes)
        Repo.insert_all(Ankole.Pod.Properties, properties)
        {:ok, :inserted}
      end)
  end
end
