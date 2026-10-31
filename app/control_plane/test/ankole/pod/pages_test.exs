defmodule Ankole.Pod.PagesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ
  alias Ankole.Pod.{Access, Documents, Page, PageChange, PageContent, Pages, PageUserState}

  setup do
    owner = human_fixture().principal
    reader = human_fixture().principal
    agent = agent_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    %{owner: owner, reader: reader, agent: agent}
  end

  test "an untitled Page still requires an explicit empty title base", ctx do
    actor = actor_fixture(ctx.owner)
    {:ok, page} = Pages.create(actor, %{})

    assert {:error, {:title_conflict, ""}} = Pages.update(actor, page.id, %{title: "First title"})

    assert {:ok, %{title: "First title"}} =
             Pages.update(actor, page.id, %{title: "First title", expected_title: ""})
  end

  test "a Page title holds at most 255 characters", ctx do
    actor = actor_fixture(ctx.owner)
    longest = String.duplicate("标", 255)

    assert {:error, _} = Pages.create(actor, %{title: longest <> "x"})
    assert {:ok, page} = Pages.create(actor, %{title: longest})
    assert page.title == longest

    assert {:error, _} =
             Pages.update(actor, page.id, %{title: longest <> "x", expected_title: longest})

    assert {:ok, %{title: "Short"}} =
             Pages.update(actor, page.id, %{title: "Short", expected_title: longest})
  end

  test "a legacy title above 255 characters stays while the icon changes", ctx do
    actor = actor_fixture(ctx.owner)
    {:ok, page} = Pages.create(actor, %{title: "Legacy"})
    legacy = String.duplicate("标", 300)

    Ankole.Repo.query!("UPDATE pages SET title = $1 WHERE id = $2", [
      legacy,
      Ecto.UUID.dump!(page.id)
    ])

    assert {:ok, %{title: ^legacy, icon: "📌"}} = Pages.update(actor, page.id, %{icon: "📌"})
  end

  test "moving the first Space page into Private establishes its owner's access", ctx do
    actor = actor_fixture(ctx.owner.uid)
    assert {:ok, []} = Pages.list(actor, %{scope: "private"})
    assert {:ok, page} = Pages.create(actor, %{title: "First private page"})

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
               grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
             })

    assert {:error, :forbidden} =
             Pages.move(actor, page.id, %{private_owner_uid: ctx.reader.uid})

    assert {:ok, %{page: moved}} =
             Pages.move(actor, page.id, %{private_owner_uid: ctx.owner.uid})

    assert moved.private_owner_uid == ctx.owner.uid
    assert {:ok, [visible]} = Pages.list(actor, %{scope: "private"})
    assert visible.id == page.id
    assert {:ok, _} = Pages.authorize(actor, page.id, "page_manage")
    assert {:ok, _} = Pages.authorize(actor_fixture(ctx.reader.uid), page.id, "page_view")
  end

  test "an ancestor path uses one query and still rejects a cycle", ctx do
    {:ok, root} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Root"})

    {:ok, middle} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: root.id})

    {:ok, leaf} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: middle.id})

    handler = "page-path-#{leaf.id}"
    owner = self()

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, _, pid ->
        if self() == pid, do: send(pid, :path_query)
      end,
      owner
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, path} = Access.path(leaf)
    assert Enum.map(path, & &1.id) == [root.id, middle.id, leaf.id]
    assert_receive :path_query
    refute_receive :path_query
    :telemetry.detach(handler)

    Repo.update!(
      Ecto.Changeset.change(root,
        parent_id: leaf.id,
        inherit_permissions: false,
        parent_anchor_id: middle.id
      )
    )

    assert {:error, :invalid_tree} = Access.path(leaf)
  end

  test "document creation commits validated content and rolls back an invalid document", ctx do
    actor = actor_fixture(ctx.owner.uid)

    assert {:ok, page} =
             Pages.create(actor, %{
               title: "Saved message",
               xml: "<page><p>Complete body</p></page>"
             })

    assert {:ok, %{content: %{content: "<page><p>Complete body</p></page>"}}} =
             Pages.get(actor, page.id)

    before = Repo.aggregate(Page, :count)
    assert {:error, _} = Pages.create(actor, %{title: "Invalid message", xml: "<page><p>"})
    assert Repo.aggregate(Page, :count) == before
  end

  test "all-page discovery includes ordinary children and search returns visible ancestors",
       ctx do
    actor = actor_fixture(ctx.owner.uid)
    {:ok, root} = Pages.create(actor, %{title: "Root"})
    {:ok, middle} = Pages.create(actor, %{title: "Middle", parent_id: root.id})
    {:ok, leaf} = Pages.create(actor, %{title: "Needle", parent_id: middle.id})
    assert {:ok, pages} = Pages.list(actor, %{scope: "all"})
    assert leaf.id in Enum.map(pages, & &1.id)
    assert {:ok, %{pages: [found], ancestors: ancestors}} = Pages.search(actor, "Needle")
    assert found.id == leaf.id
    assert MapSet.new(ancestors, & &1.id) == MapSet.new([root.id, middle.id])
  end

  test "a page read returns the ancestors its reader can open, from the root down to the parent",
       ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = actor_fixture(ctx.reader.uid)

    {:ok, root} =
      Pages.create(owner, %{title: "Restricted root", private_owner_uid: ctx.owner.uid})

    {:ok, middle} = Pages.create(owner, %{title: "Shared middle", parent_id: root.id})
    {:ok, leaf} = Pages.create(owner, %{title: "Leaf", parent_id: middle.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, middle.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
      })

    assert {:ok, %{ancestors: [%Page{id: root_id}, %Page{id: middle_id}]}} =
             Pages.get(owner, leaf.id)

    assert {root_id, middle_id} == {root.id, middle.id}

    assert {:ok, %{ancestors: [%Page{id: ^middle_id, title: "Shared middle"}]}} =
             Pages.get(reader, leaf.id)

    assert {:ok, %{ancestors: []}} = Pages.get(owner, root.id)
  end

  test "the trash notice counts live descendants that the deleting manager can view", ctx do
    owner = actor_fixture(ctx.owner.uid)
    manager = actor_fixture(ctx.reader.uid)
    {:ok, parent} = Pages.create(owner, %{title: "Parent", private_owner_uid: ctx.owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, parent.id, %{
        grants: [%{principal_uid: ctx.reader.uid, role: "manage"}]
      })

    {:ok, child} = Pages.create(owner, %{title: "Child", parent_id: parent.id})
    {:ok, _} = Pages.create(owner, %{title: "Grandchild", parent_id: child.id})
    {:ok, hidden} = Pages.create(owner, %{title: "Hidden", parent_id: parent.id})
    {:ok, trashed} = Pages.create(owner, %{title: "Trashed", parent_id: parent.id})
    {:ok, _} = Pages.delete(owner, trashed.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, hidden.id, %{
        inherit_permissions: false,
        grants: []
      })

    assert Pages.visible_descendant_count(owner, parent.id) == 3
    assert Pages.visible_descendant_count(manager, parent.id) == 2
    assert Pages.visible_descendant_count(owner, child.id) == 1
  end

  test "an editor can remove their own inherited inline child", ctx do
    owner = actor_fixture(ctx.owner.uid)
    editor = actor_fixture(ctx.reader.uid)
    {:ok, parent} = Pages.create(owner, %{})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, parent.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.reader.uid, role: "edit"}]
      })

    {:ok, child} = Pages.create(editor, %{parent_id: parent.id})
    assert {:error, :forbidden} = Pages.authorize(editor, child.id, "page_manage")
    assert {:ok, nil} = Pages.delete_embeds(editor, parent.id, [child.id])
    assert %DateTime{} = Repo.get!(Page, child.id).deleted_at
  end

  test "trash scans past 200 inaccessible candidates with its database timestamp cursor", ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = actor_fixture(ctx.reader.uid)

    {:ok, visible} =
      Pages.create(owner, %{title: "Accessible trash", private_owner_uid: ctx.owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, visible.id, %{
        grants: [%{principal_uid: ctx.reader.uid, role: "manage"}]
      })

    {:ok, _} = Pages.delete(owner, visible.id)

    for _ <- 1..201 do
      {:ok, hidden} = Pages.create(owner, %{private_owner_uid: ctx.owner.uid})
      {:ok, _} = Pages.delete(owner, hidden.id)
    end

    assert {:ok, [found]} = Pages.list(reader, %{scope: "trash"})
    assert found.id == visible.id
  end

  test "document contribution permits comments and reaches descendant records only with container scope",
       ctx do
    owner = actor_fixture(ctx.owner.uid)
    contributor = actor_fixture(ctx.reader.uid)
    {:ok, page} = Pages.create(owner, %{private_owner_uid: ctx.owner.uid})
    {:ok, base} = Pages.create(owner, %{parent_id: page.id, type: "base"})
    {:ok, table} = Ankole.Pod.Bases.create_table(owner, base.id, %{name: "Records"})

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
               grants: [
                 %{principal_uid: ctx.reader.uid, role: "contribute", target_scope: "self"}
               ]
             })

    assert {:ok, _} =
             Ankole.Pod.Comments.create(contributor, page.id, %{body: "A document comment"})

    assert {:error, :forbidden} =
             Documents.write(contributor, page.id, 0, "<page><p>Changed body</p></page>")

    assert {:error, :forbidden} =
             Ankole.Pod.Bases.write_records(contributor, table.id, %{creates: [%{data: %{}}]})

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
               grants: [
                 %{principal_uid: ctx.reader.uid, role: "contribute", target_scope: "container"}
               ]
             })

    assert {:ok, %{records: [_]}} =
             Ankole.Pod.Bases.write_records(contributor, table.id, %{creates: [%{data: %{}}]})
  end

  test "space default roles, Private, explicit Agent admission, and restricted roots use AuthZ",
       ctx do
    {:ok, shared} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid), %{title: "Shared"})

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid), %{
        private_owner_uid: ctx.reader.uid,
        title: "Private"
      })

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               shared.id,
               "page_manage"
             )

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               private.id,
               "page_view"
             )

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               shared.id,
               "page_view"
             )

    assert {:ok, _} =
             Pages.set_space(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), "edit")

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid),
               shared.id,
               "page_manage"
             )

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               shared.id,
               "page_manage"
             )

    assert {:ok, _} =
             Pages.space_agent(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               ctx.agent.uid,
               "view"
             )

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               shared.id,
               "page_view"
             )

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               shared.id,
               "page_edit"
             )

    assert {:ok, restricted} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, shared.id, %{
               inherit_permissions: false
             })

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid),
               restricted.id,
               "page_view"
             )

    assert {:ok, []} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid), %{scope: "space"})

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               restricted.id,
               "page_manage"
             )

    assert Enum.all?(Access.page_grants(restricted.id), &(&1.condition == "true"))
  end

  test "move accepts all page types, rejects cycles, and preserves direct shares",
       ctx do
    {:ok, root} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Space"})

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        title: "Child",
        parent_id: root.id
      })

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        title: "Private",
        private_owner_uid: ctx.owner.uid
      })

    {:ok, leaf} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        type: "file",
        parent_id: root.id
      })

    assert {:error, :cycle} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id, %{
               parent_id: child.id
             })

    assert {:ok, %{page: moved}} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), child.id, %{
               parent_id: leaf.id
             })

    assert moved.parent_id == leaf.id

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    {:ok, _} =
      Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), child.id, %{
        parent_id: private.id
      })

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid),
               child.id,
               "page_view"
             )

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               child.id,
               "page_view"
             )

    {:ok, shared} =
      Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid), %{scope: "shared"})

    assert Enum.map(shared, & &1.id) == [child.id]
  end

  test "a move places the page next to one sibling and rejects a stale anchor", ctx do
    {:ok, root} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Root"})

    [a, b, c] = for title <- ~w(A B C), do: create_child(ctx.owner.uid, root.id, title)

    {:ok, other} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Other"})

    order = fn ->
      from(p in Page,
        where: p.parent_id == ^root.id,
        order_by: [p.position, p.id],
        select: p.title
      )
      |> Repo.all()
    end

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), c.id, %{
               parent_id: root.id,
               before_id: a.id
             })

    assert order.() == ~w(C A B)

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), c.id, %{
               parent_id: root.id,
               after_id: a.id
             })

    assert order.() == ~w(A C B)

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), a.id, %{
               parent_id: root.id,
               after_id: b.id
             })

    assert order.() == ~w(C B A)

    assert {:error, :position_conflict} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), b.id, %{
               parent_id: root.id,
               after_id: other.id
             })

    assert {:error, :position_conflict} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), b.id, %{
               parent_id: root.id,
               after_id: b.id
             })

    assert {:error, :invalid_position} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), b.id, %{
               parent_id: root.id,
               after_id: a.id,
               before_id: c.id
             })

    assert {:ok, %{page: moved}} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), other.id, %{
               parent_id: root.id,
               after_id: c.id
             })

    assert moved.parent_id == root.id
    assert order.() == ~w(C Other B A)
  end

  test "creating and moving without an anchor appends within the destination", ctx do
    {:ok, root} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Root"})

    first = create_child(ctx.owner.uid, root.id, "First")
    second = create_child(ctx.owner.uid, root.id, "Second")
    assert first.position < second.position

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        title: "Private",
        private_owner_uid: ctx.owner.uid
      })

    assert private.position == root.position

    {:ok, other} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Other"})

    only_child = create_child(ctx.owner.uid, other.id, "Only child")
    assert only_child.position == first.position

    assert {:ok, %{page: moved}} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), only_child.id, %{
               parent_id: root.id
             })

    assert moved.position > second.position

    assert {:ok, %{pages: children}} =
             Pages.list_children(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id)

    assert Enum.map(children, & &1.title) == ["First", "Second", "Only child"]
  end

  test "a move renumbers siblings whose keys cannot be ordered", ctx do
    {:ok, root} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{title: "Root"})

    [a, b, c] = for title <- ~w(A B C), do: create_child(ctx.owner.uid, root.id, title)
    from(p in Page, where: p.id in ^[a.id, b.id]) |> Repo.update_all(set: [position: "V"])
    [first, second] = Enum.sort([a.id, b.id])

    assert {:ok, _} =
             Pages.move(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), c.id, %{
               parent_id: root.id,
               after_id: first
             })

    positions =
      from(p in Page, where: p.parent_id == ^root.id, order_by: [p.position, p.id], select: p.id)
      |> Repo.all()

    assert positions == [first, c.id, second]

    assert from(p in Page, where: p.parent_id == ^root.id, select: p.position)
           |> Repo.all()
           |> Enum.uniq()
           |> length() == 3
  end

  defp create_child(uid, parent_id, title) do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{
        parent_id: parent_id,
        title: title
      })

    page
  end

  test "trash hides shared descendants, restores the subtree, and refuses a started purge", ctx do
    {:ok, root} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{parent_id: root.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id)

    assert {:error, :not_found} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               child.id,
               "page_view"
             )

    assert {:ok, []} = Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid))

    assert {:ok, [trashed]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{scope: "trash"})

    assert trashed.id == root.id
    {:ok, _} = Pages.restore(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id)

    assert {:ok, _} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               child.id,
               "page_view"
             )

    {:ok, root} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id)
    Ankole.Pod.PagesFixtures.update_record!(root, :begin_purge)

    assert {:error, :cannot_restore} =
             Pages.restore(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), root.id)
  end

  test "trash reads only the deleted root and keeps page writes closed", ctx do
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid)

    {:ok, root} =
      Pages.create(actor, %{
        title: "Readable trash",
        xml: "<page><p>Readable body</p></page>"
      })

    {:ok, child} = Pages.create(actor, %{parent_id: root.id, title: "Hidden child"})
    {:ok, _} = Pages.delete(actor, root.id)

    assert {:ok, %{page: page, content: content}} = Pages.get(actor, root.id)
    assert page.id == root.id
    assert page.deleted_at
    assert "page_manage" in page.actions
    assert content.plain_text == "Readable body"
    assert {:error, :not_found} = Pages.get(actor, child.id)
    assert {:error, :not_found} = Pages.update(actor, root.id, %{title: "Changed"})
    assert {:error, :not_found} = Pages.state(actor, root.id, %{favorite: true})
  end

  test "permanent deletion starts the existing purge job only for a deleted root", ctx do
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid)
    {:ok, root} = Pages.create(actor, %{title: "Purge root"})
    {:ok, child} = Pages.create(actor, %{parent_id: root.id, title: "Purge child"})

    assert {:error, :cannot_purge} = Pages.purge(actor, root.id)
    {:ok, _} = Pages.delete(actor, root.id)
    assert {:error, :not_found} = Pages.purge(actor, child.id)

    assert {:ok, purging} = Pages.purge(actor, root.id)
    assert purging.purge_started_at
    assert {:error, :cannot_restore} = Pages.restore(actor, root.id)
    assert {:error, :cannot_purge} = Pages.purge(actor, root.id)

    assert Enum.any?(Repo.all(Oban.Job), fn job ->
             job.worker == "Ankole.Pod.Jobs.PurgePage" and job.args["page_id"] == root.id and
               job.state == "available"
           end)

    assert :ok = Ankole.Pod.Jobs.PurgePage.run(%Oban.Job{args: %{"page_id" => root.id}})
    assert {:error, :not_found} = Pages.fetch(root.id)
    assert {:error, :not_found} = Pages.fetch(child.id)
  end

  test "deleting an embed trashes its direct child and can unlink hidden or missing references",
       ctx do
    {:ok, parent} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, child} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        type: "base",
        parent_id: parent.id
      })

    {:ok, referenced} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid), %{
        type: "base",
        private_owner_uid: ctx.reader.uid
      })

    assert {:ok, nil} =
             Pages.delete_embeds(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               parent.id,
               [referenced.id]
             )

    assert {:ok, nil} =
             Pages.delete_embeds(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               parent.id,
               [Ecto.UUID.generate()]
             )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.reader.uid, referenced.id, %{
        grants: [%{principal_uid: ctx.owner.uid, role: "view"}]
      })

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               referenced.id,
               "page_manage"
             )

    assert {:ok, nil} =
             Pages.delete_embeds(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               parent.id,
               [referenced.id]
             )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, parent.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
      })

    assert {:error, :forbidden} =
             Pages.delete_embeds(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               parent.id,
               [child.id]
             )

    assert {:error, :forbidden} =
             Pages.delete_embeds(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent.uid),
               referenced.id,
               [child.id]
             )

    assert {:ok, nil} =
             Pages.delete_embeds(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               parent.id,
               [child.id]
             )

    assert %DateTime{} = Repo.get!(Page, child.id).deleted_at

    assert is_nil(Repo.get!(Page, referenced.id).deleted_at)
  end

  test "batch embed deletion rolls back every child and purge job when one child is forbidden",
       ctx do
    owner = actor_fixture(ctx.owner.uid)
    editor = actor_fixture(ctx.reader.uid)
    {:ok, parent} = Pages.create(owner, %{})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, parent.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.reader.uid, role: "edit"}]
      })

    {:ok, own_child} = Pages.create(editor, %{parent_id: parent.id})
    {:ok, other_child} = Pages.create(owner, %{parent_id: parent.id})
    assert own_child.id < other_child.id
    before_jobs = Repo.aggregate(Oban.Job, :count)

    assert {:error, :forbidden} =
             Pages.delete_embeds(editor, parent.id, [own_child.id, other_child.id])

    assert is_nil(Repo.get!(Page, own_child.id).deleted_at)
    assert is_nil(Repo.get!(Page, other_child.id).deleted_at)
    assert Repo.aggregate(Oban.Job, :count) == before_jobs

    assert {:ok, nil} =
             Pages.delete_embeds(owner, parent.id, [own_child.id, other_child.id, own_child.id])

    assert %DateTime{} = Repo.get!(Page, own_child.id).deleted_at
    assert %DateTime{} = Repo.get!(Page, other_child.id).deleted_at
  end

  test "whole document CAS validates XML before commit and logs incremental changes", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    assert {:ok, %{page: %{revision: 1}}} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               0,
               "<page><paragraph>Hello</paragraph></page>"
             )

    assert {:error, {:revision_conflict, 1}} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               0,
               "<page />"
             )

    assert {:error, {:revision_conflict, 1}} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               0,
               "<html />"
             )

    {:ok, private} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    assert {:error, :forbidden} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid),
               private.id,
               0,
               "<html />"
             )

    assert {:error, :not_found} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               Ecto.UUID.generate(),
               0,
               "<html />"
             )

    {:ok, file} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{type: "file"})

    assert {:error, :invalid_page_type} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               file.id,
               0,
               "<html />"
             )

    assert {:error, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               1,
               "<html />"
             )

    assert Repo.get!(Page, page.id).revision == 1
    assert Repo.get!(PageContent, page.id).plain_text =~ "Hello"
    assert [%{kind: :change, revision: 1}] = Repo.all(PageChange)

    assert {:ok, %{changes: [%{kind: :change}], revision: 1}} =
             Documents.since(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, 0)
  end

  test "personal and shared lists evaluate permissions once and project the visible page's rights",
       ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = actor_fixture(ctx.reader.uid)
    {:ok, page} = Pages.create(owner, %{private_owner_uid: ctx.owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
      })

    {:ok, _} = Pages.state(reader, page.id, %{favorite: true, visited: true})
    function = {Ankole.Kernel, :authz_evaluate_pod_context, 1}

    for scope <- ["recent", "favorites", "shared"] do
      :erlang.trace_pattern(function, true, [:call_count])

      try do
        assert {:ok, [visible]} = Pages.list(reader, %{scope: scope})
        assert visible.id == page.id
        assert visible.actions == ["page_view"]
        assert :erlang.trace_info(function, :call_count) == {:call_count, 1}
      after
        :erlang.trace_pattern(function, false, [:call_count])
      end
    end
  end

  test "favorites, recents, and text search never reveal inaccessible pages", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        title: "Needle",
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
        favorite: true,
        visited: true
      })

    assert {:ok, [found]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
               scope: "favorites"
             })

    assert found.id == page.id

    assert {:ok, [_]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{scope: "recent"})

    assert {:ok, [_]} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{query: "needle"})

    assert {:ok, []} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader.uid), %{
               query: "needle"
             })

    {:ok, _} =
      Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
        favorite: false
      })

    assert {:ok, []} =
             Pages.list(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
               scope: "favorites"
             })
  end

  test "text search matches every word in the title or body in any order", ctx do
    actor = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid)

    {:ok, page} =
      Pages.create(actor, %{
        title: "季度 report",
        xml: "<page><p>Revenue grew while 留存 held</p></page>"
      })

    {:ok, _} = Pages.state(actor, page.id, %{favorite: true})

    assert {:ok, %{pages: [found]}} = Pages.search(actor, "留存  季度")
    assert found.id == page.id
    assert {:ok, %{pages: []}} = Pages.search(actor, "留存 missing")
    assert {:ok, [_]} = Pages.list(actor, %{query: "held revenue"})
    assert {:ok, [_]} = Pages.list(actor, %{scope: "favorites", query: "report grew"})

    # Only the first 16 distinct words filter, so a word after them does not exclude the Page.
    present = ~w(Revenue grew while held report 季度 留存 Rev gre whi hel rep 季 留 eve rew)
    assert {:ok, %{pages: [_]}} = Pages.search(actor, Enum.join(present ++ ["absent"], " "))

    {:ok, _} = Pages.delete(actor, page.id)
    assert {:ok, [trashed]} = Pages.list(actor, %{scope: "trash", query: "grew 季度"})
    assert trashed.id == page.id
    assert {:ok, []} = Pages.list(actor, %{scope: "trash", query: "grew absent"})
  end

  test "page state preserves the other flag and removes a row with neither flag", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    key = [principal_uid: ctx.owner.uid, page_id: page.id]

    assert {:ok, _} =
             Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{})

    refute Repo.get_by(PageUserState, key)

    assert {:ok, favorite} =
             Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               favorite: true
             })

    assert favorite.favorited_at

    assert {:ok, visited} =
             Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               visited: true
             })

    assert visited.favorited_at == favorite.favorited_at
    assert visited.visited_at

    assert {:ok, _} =
             Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               favorite: false
             })

    assert %{favorited_at: nil, visited_at: at} = Repo.get_by(PageUserState, key)
    assert at == visited.visited_at

    assert {:ok, _} =
             Pages.state(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), page.id, %{
               visited: false
             })

    refute Repo.get_by(PageUserState, key)
  end

  test "other-tenant actors and page ids cannot cross the tenant boundary", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    other = create_tenant()
    foreign = Repo.with_tenant(other.id, fn -> human_fixture().principal end)

    assert {:error, :forbidden} =
             Pages.authorize(
               Ankole.PrincipalsFixtures.actor_fixture(foreign),
               page.id,
               "page_view"
             )

    Repo.with_tenant(other.id, fn ->
      assert {:error, :not_found} =
               Pages.authorize(
                 Ankole.PrincipalsFixtures.actor_fixture(foreign),
                 page.id,
                 "page_view"
               )

      assert {:ok, []} = Pages.list(Ankole.PrincipalsFixtures.actor_fixture(foreign))
    end)
  end

  test "children_view merges without touching updated_at and list_children details enriches Human, Agent, Doc, and File rows",
       ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = actor_fixture(ctx.reader.uid)
    agent = actor_fixture(ctx.agent.uid)

    assert {:ok, _} = Pages.space_agent(owner, ctx.agent.uid, "edit")

    {:ok, hub} =
      Pages.create(owner, %{
        title: "Hub",
        children_view: %{view: :grid, visible_fields: [:created_by]}
      })

    assert hub.children_view == %{"view" => "grid", "visible_fields" => ["created_by"]}
    initial_updated_at = hub.updated_at

    Process.sleep(5)

    assert {:ok, updated_hub} =
             Pages.update(owner, hub.id, %{children_view: %{collapsed: true}})

    assert updated_hub.children_view == %{
             "collapsed" => true,
             "view" => "grid",
             "visible_fields" => ["created_by"]
           }

    assert DateTime.compare(updated_hub.updated_at, initial_updated_at) == :eq

    long_text = String.duplicate("Architecture overview paragraph. ", 12)
    {:ok, doc_child} = Pages.create(agent, %{parent_id: hub.id, title: "Agent Spec"})
    assert {:ok, _} = Documents.write(agent, doc_child.id, 0, "<page><p>#{long_text}</p></page>")

    {:ok, file_child} = Pages.create(owner, %{parent_id: hub.id, type: "file", title: "Diagram"})

    assert {:ok, _} =
             Ankole.Pod.Files.upload(
               owner,
               file_child.id,
               "file",
               0,
               "diagram.png",
               <<137, 80, 78, 71>>,
               "image/png"
             )

    {:ok, secret_child} = Pages.create(owner, %{parent_id: hub.id, title: "Restricted"})

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, secret_child.id, %{
               inherit_permissions: false,
               grants: [%{principal_uid: ctx.owner.uid, role: "manage"}]
             })

    assert {:ok, %{child_count: 3}} = Pages.get(owner, hub.id)
    assert {:ok, %{child_count: 2}} = Pages.get(reader, hub.id)

    assert {:ok, lightweight_dir} =
             Pages.list_children(reader, hub.id, %{details: false})

    assert length(lightweight_dir.pages) == 2
    refute Map.has_key?(lightweight_dir, :details)

    assert {:ok, %{pages: detailed, details: by_id}} =
             Pages.list_children(reader, hub.id, %{details: true})

    assert length(detailed) == 2
    assert by_id[doc_child.id].creator_name == ctx.agent.display_name
    assert String.length(by_id[doc_child.id].excerpt) == 300
    assert by_id[doc_child.id].excerpt =~ "Architecture overview paragraph."

    assert by_id[file_child.id].creator_name == ctx.owner.display_name

    assert %{path: "diagram.png", content_type: "image/png", size: 4} =
             by_id[file_child.id].file
  end

  test "delete_embeds skips already-trashed direct children idempotently while enforcing permissions on live children",
       ctx do
    owner = Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid)
    editor_principal = human_fixture().principal
    editor = Ankole.PrincipalsFixtures.actor_fixture(editor_principal.uid)

    {:ok, parent} = Pages.create(owner, %{title: "Parent Doc"})

    {:ok, already_trashed} =
      Pages.create(owner, %{parent_id: parent.id, title: "Already Trashed"})

    {:ok, live_own} = Pages.create(editor, %{parent_id: parent.id, title: "Editor Child"})
    {:ok, live_protected} = Pages.create(owner, %{parent_id: parent.id, title: "Owner Child"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, parent.id, %{
        inherit_permissions: false,
        grants: [
          %{principal_uid: ctx.owner.uid, role: "manage"},
          %{principal_uid: editor_principal.uid, role: "edit"}
        ]
      })

    assert {:ok, _} = Pages.delete(owner, already_trashed.id)

    assert {:error, :forbidden} =
             Pages.delete_embeds(editor, parent.id, [already_trashed.id, live_protected.id])

    assert {:ok, %{deleted_at: nil}} = Pages.fetch(live_protected.id)

    assert {:ok, nil} =
             Pages.delete_embeds(editor, parent.id, [already_trashed.id, live_own.id])

    assert {:ok, %{deleted_at: %DateTime{}}} = Pages.fetch(live_own.id)
    assert {:ok, %{deleted_at: %DateTime{}}} = Pages.fetch(already_trashed.id)
  end
end
