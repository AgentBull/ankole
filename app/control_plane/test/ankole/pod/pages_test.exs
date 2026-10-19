defmodule Ankole.Pod.PagesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AuthZ
  alias Ankole.Pod.{Access, Documents, Page, PageChange, PageContent, Pages}

  setup do
    owner = human_fixture().principal
    reader = human_fixture().principal
    agent = agent_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "**",
        action: "update"
      })

    %{owner: owner, reader: reader, agent: agent}
  end

  test "an ancestor path uses one query and still rejects a cycle", ctx do
    {:ok, root} = Pages.create(ctx.owner.uid, %{title: "Root"})
    {:ok, middle} = Pages.create(ctx.owner.uid, %{parent_id: root.id})
    {:ok, leaf} = Pages.create(ctx.owner.uid, %{parent_id: middle.id})
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

    Repo.update!(Ecto.Changeset.change(root, parent_id: leaf.id))
    assert {:error, :invalid_tree} = Access.path(leaf)
  end

  test "space default roles, Private, explicit Agent admission, and restricted roots use AuthZ",
       ctx do
    {:ok, shared} = Pages.create(ctx.reader.uid, %{title: "Shared"})

    {:ok, private} =
      Pages.create(ctx.reader.uid, %{private_owner_uid: ctx.reader.uid, title: "Private"})

    assert {:ok, _} = Pages.authorize(ctx.owner.uid, shared.id, "page_manage")
    assert {:error, :forbidden} = Pages.authorize(ctx.owner.uid, private.id, "page_view")
    assert {:error, :forbidden} = Pages.authorize(ctx.agent.uid, shared.id, "page_view")
    assert {:ok, _} = Pages.set_space(ctx.owner.uid, "edit")
    assert {:error, :forbidden} = Pages.authorize(ctx.reader.uid, shared.id, "page_manage")
    assert {:ok, _} = Pages.authorize(ctx.owner.uid, shared.id, "page_manage")
    assert {:ok, _} = Pages.space_agent(ctx.owner.uid, ctx.agent.uid, "view")
    assert {:ok, _} = Pages.authorize(ctx.agent.uid, shared.id, "page_view")
    assert {:error, :forbidden} = Pages.authorize(ctx.agent.uid, shared.id, "page_edit")

    assert {:ok, restricted} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, shared.id, %{
               inherit_permissions: false
             })

    assert {:error, :forbidden} = Pages.authorize(ctx.reader.uid, restricted.id, "page_view")
    assert {:ok, []} = Pages.list(ctx.reader.uid, %{scope: "space"})
    assert {:ok, _} = Pages.authorize(ctx.owner.uid, restricted.id, "page_manage")
    assert Enum.all?(Access.page_grants(restricted.id), &(&1.condition == "true"))
  end

  test "move changes inherited permissions, rejects cycles and leaf parents, and preserves direct shares",
       ctx do
    {:ok, root} = Pages.create(ctx.owner.uid, %{title: "Space"})
    {:ok, child} = Pages.create(ctx.owner.uid, %{title: "Child", parent_id: root.id})

    {:ok, private} =
      Pages.create(ctx.owner.uid, %{title: "Private", private_owner_uid: ctx.owner.uid})

    {:ok, leaf} = Pages.create(ctx.owner.uid, %{type: "file", parent_id: root.id})
    assert {:error, :cycle} = Pages.move(ctx.owner.uid, root.id, %{parent_id: child.id})
    assert {:error, :invalid_parent} = Pages.move(ctx.owner.uid, child.id, %{parent_id: leaf.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    {:ok, _} = Pages.move(ctx.owner.uid, child.id, %{parent_id: private.id})
    assert {:error, :forbidden} = Pages.authorize(ctx.reader.uid, child.id, "page_view")
    assert {:ok, _} = Pages.authorize(ctx.agent.uid, child.id, "page_view")
    {:ok, shared} = Pages.list(ctx.agent.uid, %{scope: "shared"})
    assert Enum.map(shared, & &1.id) == [child.id]
  end

  test "trash hides shared descendants, restores the subtree, and refuses a started purge", ctx do
    {:ok, root} = Pages.create(ctx.owner.uid, %{})
    {:ok, child} = Pages.create(ctx.owner.uid, %{parent_id: root.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, child.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "view"}]
      })

    {:ok, _} = Pages.delete(ctx.owner.uid, root.id)
    assert {:error, :not_found} = Pages.authorize(ctx.agent.uid, child.id, "page_view")
    assert {:ok, []} = Pages.list(ctx.agent.uid)
    assert {:ok, [trashed]} = Pages.list(ctx.owner.uid, %{scope: "trash"})
    assert trashed.id == root.id
    {:ok, _} = Pages.restore(ctx.owner.uid, root.id)
    assert {:ok, _} = Pages.authorize(ctx.agent.uid, child.id, "page_view")
    {:ok, root} = Pages.delete(ctx.owner.uid, root.id)
    Repo.update!(Page.changeset(root, %{purge_started_at: DateTime.utc_now(:microsecond)}))
    assert {:error, :cannot_restore} = Pages.restore(ctx.owner.uid, root.id)
  end

  test "deleting an embed trashes its direct child and can unlink hidden or missing references",
       ctx do
    {:ok, parent} = Pages.create(ctx.owner.uid, %{})
    {:ok, child} = Pages.create(ctx.owner.uid, %{type: "database", parent_id: parent.id})

    {:ok, referenced} =
      Pages.create(ctx.reader.uid, %{type: "database", private_owner_uid: ctx.reader.uid})

    assert {:ok, nil} = Pages.delete_embed(ctx.owner.uid, parent.id, referenced.id)
    assert {:ok, nil} = Pages.delete_embed(ctx.owner.uid, parent.id, Ecto.UUID.generate())

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.reader.uid, referenced.id, %{
        grants: [%{principal_uid: ctx.owner.uid, role: "view"}]
      })

    assert {:error, :forbidden} = Pages.authorize(ctx.owner.uid, referenced.id, "page_manage")
    assert {:ok, nil} = Pages.delete_embed(ctx.owner.uid, parent.id, referenced.id)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, parent.id, %{
        grants: [%{principal_uid: ctx.agent.uid, role: "edit"}]
      })

    assert {:error, :forbidden} = Pages.delete_embed(ctx.agent.uid, parent.id, child.id)
    assert {:error, :forbidden} = Pages.delete_embed(ctx.agent.uid, referenced.id, child.id)
    assert {:ok, nil} = Pages.delete_embed(ctx.owner.uid, parent.id, child.id)
    assert %DateTime{} = Repo.get!(Page, child.id).deleted_at

    assert is_nil(Repo.get!(Page, referenced.id).deleted_at)
  end

  test "whole document CAS validates XML before commit and logs resets", ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{})

    assert {:ok, %{page: %{revision: 1}}} =
             Documents.write(
               ctx.owner.uid,
               page.id,
               0,
               "<page><paragraph>Hello</paragraph></page>"
             )

    assert {:error, {:revision_conflict, 1}} =
             Documents.write(ctx.owner.uid, page.id, 0, "<page />")

    assert {:error, {:revision_conflict, 1}} =
             Documents.write(ctx.owner.uid, page.id, 0, "<html />")

    {:ok, private} = Pages.create(ctx.owner.uid, %{private_owner_uid: ctx.owner.uid})
    assert {:error, :forbidden} = Documents.write(ctx.reader.uid, private.id, 0, "<html />")

    assert {:error, :not_found} =
             Documents.write(ctx.owner.uid, Ecto.UUID.generate(), 0, "<html />")

    {:ok, file} = Pages.create(ctx.owner.uid, %{type: "file"})
    assert {:error, :invalid_page_type} = Documents.write(ctx.owner.uid, file.id, 0, "<html />")

    assert {:error, _} = Documents.write(ctx.owner.uid, page.id, 1, "<html />")
    assert Repo.get!(Page, page.id).revision == 1
    assert Repo.get!(PageContent, page.id).plain_text =~ "Hello"
    assert [%{kind: :reset, revision: 1}] = Repo.all(PageChange)

    assert {:ok, %{changes: [%{kind: :reset}], revision: 1}} =
             Documents.since(ctx.owner.uid, page.id, 0)
  end

  test "favorites, recents, and text search never reveal inaccessible pages", ctx do
    {:ok, page} =
      Pages.create(ctx.owner.uid, %{title: "Needle", private_owner_uid: ctx.owner.uid})

    {:ok, _} = Pages.state(ctx.owner.uid, page.id, %{favorite: true, visited: true})
    assert {:ok, [found]} = Pages.list(ctx.owner.uid, %{scope: "favorites"})
    assert found.id == page.id
    assert {:ok, [_]} = Pages.list(ctx.owner.uid, %{scope: "recent"})
    assert {:ok, [_]} = Pages.list(ctx.owner.uid, %{query: "needle"})
    assert {:ok, []} = Pages.list(ctx.reader.uid, %{query: "needle"})
    {:ok, _} = Pages.state(ctx.owner.uid, page.id, %{favorite: false})
    assert {:ok, []} = Pages.list(ctx.owner.uid, %{scope: "favorites"})
  end

  test "other-tenant actors and page ids cannot cross the tenant boundary", ctx do
    {:ok, page} = Pages.create(ctx.owner.uid, %{})
    other = create_tenant()
    foreign = Repo.with_tenant(other.id, fn -> human_fixture().principal end)
    assert {:error, :forbidden} = Pages.authorize(foreign.uid, page.id, "page_view")

    Repo.with_tenant(other.id, fn ->
      assert {:error, :not_found} = Pages.authorize(foreign.uid, page.id, "page_view")
      assert {:ok, []} = Pages.list(foreign.uid)
    end)
  end
end
