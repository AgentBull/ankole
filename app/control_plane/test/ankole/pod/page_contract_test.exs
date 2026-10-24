defmodule Ankole.Pod.PageContractTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Documents, Page, PageChange, PageContent, Pages}

  setup do
    owner = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: owner.uid}).principal
    %{owner: owner, agent: agent}
  end

  test "a new blank page is editable and retransmission applies each OT batch once", ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{})
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
             Documents.apply(ctx.owner.uid, page.id, batch)

    assert {:ok, %{revision: 1, acknowledged_revision: 1}} =
             Documents.apply(ctx.owner.uid, page.id, batch)

    assert Repo.get!(PageContent, page.id).content == "<page><p>Hello</p></page>"
    assert Repo.aggregate(PageChange, :count) == 1

    assert {:ok, %{revision: 1, changes: [%{client_seq: 1}]}} =
             Documents.apply(ctx.owner.uid, page.id, %{batch | client_seq: 2})

    assert Repo.get!(Page, page.id).revision == 1
  end

  test "a reused client sequence with another payload rejects the new edit", ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{})

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

    assert {:ok, %{revision: 1}} = Documents.apply(ctx.owner.uid, page.id, batch)

    assert {:error, :client_sequence_conflict} =
             Documents.apply(ctx.owner.uid, page.id, %{
               batch
               | changes: [[0, [%{"type" => "Text", "param" => "Different"}]], 1]
             })

    assert Repo.get!(PageContent, page.id).content == "<page><p>Original</p></page>"
  end

  test "replay asks for a snapshot before loading a log larger than the socket message budget",
       ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{})
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
             Documents.since(ctx.owner.uid, page.id, 0)

    assert {:ok, %{revision: 2, changes: [_], reset_required: false}} =
             Documents.since(ctx.owner.uid, page.id, 1)
  end

  test "an Agent reset is visible to stale clients and rejected Agent writes leave content intact",
       ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{private_owner_uid: ctx.owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
      })

    assert {:ok, %{page: %{revision: 1}}} =
             Documents.write(ctx.agent.uid, page.id, 0, "<page><p>Agent</p></page>")

    assert {:error, {:revision_conflict, 1}} =
             Documents.write(ctx.agent.uid, page.id, 0, "<page />")

    assert {:error, _} =
             Documents.write(ctx.agent.uid, page.id, 1, "<page><p><table /></p></page>")

    assert Repo.get!(PageContent, page.id).content == "<page><p>Agent</p></page>"

    assert {:ok, %{changes: [%{kind: :reset}], reset_required: false}} =
             Documents.since(ctx.owner.uid, page.id, 0)

    Repo.delete_all(PageChange)

    assert {:ok, %{changes: [], reset_required: true}} =
             Documents.since(ctx.owner.uid, page.id, 0)

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{grants: []})
    assert {:error, :forbidden} = Documents.since(ctx.agent.uid, page.id, 0)
    assert {:error, :forbidden} = Documents.write(ctx.agent.uid, page.id, 1, "<page />")
  end

  test "trash retention defaults to 30 days and is checked again when a job runs", ctx do
    assert {:ok, 30} = Ankole.Pod.Config.trash_retention_days()
    {:ok, page} = Pages.create(ctx.owner.uid, %{})
    {:ok, _} = Pages.delete(ctx.owner.uid, page.id)

    assert_enqueued(
      worker: Ankole.Pod.Jobs.PurgePage,
      args: %{page_id: page.id, tenant_id: Repo.tenant_id!()}
    )

    assert {:snooze, seconds} =
             Ankole.Pod.Jobs.PurgePage.perform(%Oban.Job{
               args: %{"tenant_id" => Repo.tenant_id!(), "page_id" => page.id}
             })

    assert seconds > 29 * 86_400
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.trash_retention_days", 60)

    assert {:snooze, longer} =
             Ankole.Pod.Jobs.PurgePage.perform(%Oban.Job{
               args: %{"tenant_id" => Repo.tenant_id!(), "page_id" => page.id}
             })

    assert longer > 59 * 86_400
    assert is_nil(Repo.get!(Page, page.id).purge_started_at)
  end

  test "OT replay retains its configured window and a pruned acknowledged retry never applies again",
       ctx do
    assert {:ok, 1000} = Ankole.Pod.Config.ot_replay_window()
    assert {:ok, _} = Ankole.AppConfigure.put_tenant_by_key("pod.ot_replay_window", 3)
    {:ok, page} = Pages.create(ctx.owner.uid, %{})

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
             Documents.apply(ctx.owner.uid, page.id, batch)

    for revision <- 1..2,
        do:
          assert(
            {:ok, _} =
              Documents.write(ctx.owner.uid, page.id, revision, "<page><p>latest</p></page>")
          )

    assert {:ok, %{revision: 3, acknowledged_revision: 1, reset_required: false}} =
             Documents.apply(ctx.owner.uid, page.id, batch)

    assert {:ok, _} = Documents.write(ctx.owner.uid, page.id, 3, "<page><p>newer</p></page>")

    assert {:ok, %{revision: 5, acknowledged_revision: 5}} =
             Documents.apply(ctx.owner.uid, page.id, %{
               base_revision: 4,
               client_id: "current-editor",
               client_seq: 1,
               changes: [6, [0, [%{"type" => "Text", "param" => "!"}]], 1]
             })

    assert Repo.aggregate(PageChange, :count) == 3

    assert {:ok,
            %{changes: [%{revision: 3}, %{revision: 4}, %{revision: 5}], reset_required: false}} =
             Documents.since(ctx.owner.uid, page.id, 2)

    assert {:ok, %{reset_required: true}} = Documents.since(ctx.owner.uid, page.id, 1)
    assert {:ok, %{reset_required: true}} = Documents.since(ctx.owner.uid, page.id, 0)

    assert {:ok, %{revision: 5, reset_required: true} = retry} =
             Documents.apply(ctx.owner.uid, page.id, batch)

    refute Map.has_key?(retry, :acknowledged_revision)
    assert Repo.get!(Page, page.id).revision == 5
    assert Repo.get!(PageContent, page.id).content == "<page><p>newer!</p></page>"
    assert Repo.aggregate(PageChange, :count) == 3
  end

  test "direct and group roles take the highest permission and stop at a restricted boundary",
       ctx do
    {:ok, root} = Pages.create(ctx.owner.uid, %{private_owner_uid: ctx.owner.uid})
    {:ok, child} = Pages.create(ctx.owner.uid, %{parent_id: root.id})

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

    assert {:ok, _} = Pages.authorize(ctx.agent.uid, child.id, "page_edit")
    assert {:error, :forbidden} = Pages.authorize(ctx.agent.uid, child.id, "page_manage")

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{inherit_permissions: false})

    assert {:error, :forbidden} = Pages.authorize(ctx.agent.uid, child.id, "page_view")
    assert {:ok, visible} = Pages.list(ctx.agent.uid)
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
    {:ok, page} = Pages.create(ctx.owner.uid, %{saved_from_message_id: attrs.message_id})

    assert {:ok, %{source_conversation: %{id: source, deleted: false}}} =
             Pages.get(ctx.owner.uid, page.id)

    assert source == detail.conversation.id

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
      })

    assert {:ok, generated} =
             Pages.create(ctx.agent.uid, %{
               parent_id: page.id,
               saved_from_message_id: attrs.message_id
             })

    assert {:ok, %{source_conversation: %{id: ^source}}} = Pages.get(ctx.agent.uid, generated.id)
    outsider = human_fixture().principal
    assert {:ok, %{source_conversation: nil}} = Pages.get(outsider.uid, page.id)
    event = Repo.get_by!(Ankole.Signals.Signal, conversation_id: detail.conversation.id)

    assert {:error, :conversation_busy} =
             Ankole.Conversations.delete(ctx.owner.uid, detail.conversation.id)

    assert {:ok, _} =
             Repo.transact(fn ->
               Ankole.Sessions.Queue.mark_event_completed_in_tx(
                 event,
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert {:ok, _} = Ankole.Conversations.delete(ctx.owner.uid, detail.conversation.id)
    assert {:ok, %{source_conversation: %{deleted: true}}} = Pages.get(ctx.owner.uid, page.id)
    assert Repo.get(Page, page.id)
  end
end
