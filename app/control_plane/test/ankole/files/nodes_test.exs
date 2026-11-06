defmodule Ankole.Pod.Pages.TreeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Repo
  alias Ankole.Pod.Access
  alias Ankole.Pod.Pages.Tree, as: Nodes
  alias Ankole.Pod.Pages
  alias Ankole.Pod.Page

  setup do
    owner = human_fixture().principal
    contributor = human_fixture().principal
    {:ok, root} = Nodes.private_root(owner.uid)
    %{owner: actor_fixture(owner), contributor: actor_fixture(contributor), root: root}
  end

  test "creating a subpage requires edit permission on an empty or populated Page", ctx do
    {:ok, parent} = Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :doc, name: "Inbox"})
    grant(ctx.contributor, parent.id)

    assert {:error, :forbidden} =
             Nodes.create(ctx.contributor, %{parent_id: parent.id, type: :doc, name: "Child"})

    assert :ok =
             Repo.transact_top_level(fn ->
               Access.put_role(
                 %{principal_uid: ctx.contributor.principal.uid},
                 "drive:**:#{parent.id}:**",
                 "edit"
               )
             end)

    assert {:ok, child} =
             Nodes.create(ctx.contributor, %{parent_id: parent.id, type: :doc, name: "Child"})

    assert child.inherit_permissions
    assert {:ok, _} = Pages.authorize(ctx.contributor, child.id, "node_edit")

    assert {:ok, _} =
             Ankole.Pod.Documents.write(ctx.owner, parent.id, 0, "<page><p>Body</p></page>")

    assert {:ok, _} =
             Nodes.create(ctx.contributor, %{parent_id: parent.id, type: :doc, name: "Another"})
  end

  test "ACL maintenance preserves modification time while node mutations advance it", ctx do
    {:ok, folder} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :doc, name: "Inbox"})

    {:ok, file} = Nodes.create(ctx.owner, %{parent_id: folder.id, type: :file, name: "File"})
    grant(ctx.contributor, folder.id)
    assert {:ok, anchored} = Nodes.fetch(folder.id)
    assert anchored.updated_at == folder.updated_at
    assert {:ok, reanchored} = Nodes.fetch(file.id)
    assert reanchored.updated_at == file.updated_at

    assert {:ok, _} = Ankole.Pod.write_node(ctx.owner, file.id, "content")
    assert {:ok, written} = Nodes.fetch(file.id)
    assert DateTime.compare(written.updated_at, file.updated_at) == :gt

    assert {:ok, renamed} = Nodes.rename(ctx.owner, file.id, "Renamed")
    assert DateTime.compare(renamed.updated_at, written.updated_at) == :gt
    assert {:ok, moved} = Nodes.move(ctx.owner, file.id, %{parent_id: ctx.root.id})
    assert DateTime.compare(moved.updated_at, renamed.updated_at) == :gt
    assert {:ok, trashed} = Nodes.trash(ctx.owner, file.id)
    assert DateTime.compare(trashed.updated_at, moved.updated_at) == :gt
    assert {:ok, restored} = Nodes.restore(ctx.owner, file.id)
    assert DateTime.compare(restored.updated_at, trashed.updated_at) == :gt
  end

  test "root contribution permits initial bytes but cannot create children", ctx do
    grant(ctx.contributor, ctx.root.id)

    assert {:error, :forbidden} =
             Nodes.create(ctx.contributor, %{
               parent_id: ctx.root.id,
               type: :file,
               name: "denied.txt"
             })

    {:ok, empty} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :file, name: "prepared.txt"})

    assert {:ok, _} = Ankole.Pod.write_node(ctx.contributor, empty.id, "initial")
    assert {:error, :forbidden} = Ankole.Pod.write_node(ctx.contributor, empty.id, "overwrite")
  end

  test "names deduplicate and restoring avoids occupied live names", ctx do
    attrs = %{parent_id: ctx.root.id, type: :file, name: "report.txt"}
    {:ok, first} = Nodes.create(ctx.owner, attrs)
    {:ok, second} = Nodes.create(ctx.owner, attrs)
    assert second.name == "report (1).txt"
    assert {:ok, _} = Nodes.trash(ctx.owner, first.id)
    assert {:ok, %{name: "report.txt"}} = Nodes.create(ctx.owner, attrs)
    assert {:ok, %{name: "report (2).txt"}} = Nodes.restore(ctx.owner, first.id)

    for name <- [
          "",
          ".",
          "..",
          "a/b",
          <<0>>,
          String.duplicate("界", 86),
          "报价单_\u202Efdp.sh",
          "hidden\u2066name.txt",
          "line\u2028break.txt"
        ] do
      assert {:error, :invalid_name} = Nodes.create(ctx.owner, %{attrs | name: name})
    end
  end

  test "name allocation probes a candidate without loading its siblings", ctx do
    attrs = %{parent_id: ctx.root.id, type: :file, name: "report.txt"}
    {:ok, first} = Nodes.create(ctx.owner, attrs)
    {:ok, second} = Nodes.create(ctx.owner, attrs)
    assert Nodes.available_name(ctx.root.id, first.name, first.id) == first.name
    assert Nodes.available_name(ctx.root.id, first.name, second.id, :file) == second.name

    handler = {__MODULE__, self()}

    :telemetry.attach(
      handler,
      [:ankole, :repo, :query],
      fn _, _, metadata, pid ->
        if self() == pid, do: send(pid, {:name_query, metadata.query, metadata.params})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert Nodes.available_name(ctx.root.id, "new.txt") == "new.txt"
    assert_receive {:name_query, query, params}
    assert query =~ "SELECT TRUE"
    assert query =~ "LIMIT 1"
    assert "new.txt" in params
    assert ctx.root.id in params or Ecto.UUID.dump!(ctx.root.id) in params
    refute_receive {:name_query, _, _}
  end

  test "Pod lists files and folders and persists favorites and sibling order", ctx do
    {:ok, folder} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :doc, name: "Folder"})

    {:ok, file} = Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :file, name: "File"})
    assert Repo.get_by!(Page, id: file.id).title == "File"
    assert {:ok, %{pages: pages}} = Pages.list_children(ctx.owner, nil, %{scope: "private"})
    assert Enum.map(pages, & &1.id) == [file.id, folder.id]

    assert {:ok, %{favorited_at: %DateTime{}}} =
             Pages.state(ctx.owner, file.id, %{favorite: true})

    assert {:ok, [favorite]} = Pages.list(ctx.owner, %{scope: "favorites"})
    assert favorite.id == file.id
    assert favorite.updated_at == file.updated_at
    assert {:ok, %{favorited_at: nil}} = Pages.state(ctx.owner, file.id, %{favorite: false})
    assert {:ok, []} = Pages.list(ctx.owner, %{scope: "favorites"})

    assert {:ok, _} =
             Pages.move(ctx.owner, folder.id, %{parent_id: ctx.root.id, before_id: file.id})

    assert {:ok, %{pages: [first, second]}} =
             Pages.list_children(ctx.owner, nil, %{scope: "private"})

    assert [first.id, second.id] == [folder.id, file.id]
    assert is_binary(first.position) and is_binary(second.position)
  end

  test "trashing an ancestor rejects descendant content and creation", ctx do
    {:ok, folder} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :doc, name: "Folder"})

    {:ok, file} = Nodes.create(ctx.owner, %{parent_id: folder.id, type: :file, name: "File"})
    assert {:ok, _} = Nodes.trash(ctx.owner, folder.id)
    assert {:error, :not_found} = Ankole.Pod.write_node(ctx.owner, file.id, "hidden")

    assert {:error, :not_found} =
             Nodes.create(ctx.owner, %{parent_id: folder.id, type: :file, name: "Other"})
  end

  test "an isolated manage grant does not permit changing a file name", ctx do
    {:ok, file} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :file, name: "Original"})

    assert {:ok, _} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: ctx.contributor.principal.uid,
               resource_pattern: "drive:**:#{file.id}:node",
               action: "node_manage"
             })

    assert {:error, :forbidden} = Nodes.rename(ctx.contributor, file.id, "Changed")
    assert {:ok, %{name: "Original"}} = Nodes.fetch(file.id)
  end

  test "permanent subtree cleanup removes the Base physical table before its metadata", ctx do
    alias Ankole.Pod.{Bases, BaseRepo}
    assert {:ok, page} = Pages.create(ctx.owner, %{type: "base", parent_id: ctx.root.id})
    assert {:ok, %{tables: [table]}} = Bases.list_tables(ctx.owner, page.id)

    assert {:ok, _} =
             Bases.create_field(ctx.owner, table.id, %{
               name: "Link",
               type: "link",
               config: %{"table_id" => table.id}
             })

    exists = fn ->
      BaseRepo.with_shard(BaseRepo.shard!(), fn ->
        BaseRepo.query!("SELECT to_regclass($1) IS NOT NULL", [BaseRepo.table(table.id)]).rows
      end)
    end

    assert exists.() == [[true]]
    assert {:ok, _} = Nodes.trash(ctx.owner, page.id)
    assert {:ok, _} = Nodes.purge(ctx.owner, page.id)
    assert :ok = Ankole.Pod.Jobs.PurgeTree.run(%Oban.Job{args: %{"node_id" => page.id}})
    assert exists.() == [[false]]
    assert {:error, :not_found} = Nodes.fetch(page.id)
    refute Repo.get_by(Ankole.Pod.BaseTable, id: table.id)
  end

  test "restoring a folder recovers authorized descendants, resolves names, and leaves restricted trash alone",
       ctx do
    {:ok, folder} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, type: :doc, name: "Project"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.principal, folder.id, %{
        grants: [%{principal_uid: ctx.contributor.principal.uid, role: "manage"}]
      })

    {:ok, first} =
      Nodes.create(ctx.owner, %{parent_id: folder.id, type: :file, name: "report.txt"})

    assert {:ok, _} = Nodes.trash(ctx.owner, first.id)

    {:ok, second} =
      Nodes.create(ctx.owner, %{parent_id: folder.id, type: :file, name: "report.txt"})

    assert {:ok, _} = Nodes.trash(ctx.owner, second.id)

    {:ok, restricted} =
      Nodes.create(ctx.owner, %{parent_id: folder.id, type: :file, name: "Restricted"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.principal, restricted.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.owner.principal.uid, role: "manage"}]
      })

    assert {:ok, _} = Nodes.trash(ctx.owner, restricted.id)
    assert {:ok, _} = Nodes.trash(ctx.owner, folder.id)
    assert {:ok, trash} = Pages.list(ctx.owner, %{scope: "trash"})
    assert Enum.map(trash, & &1.id) == [folder.id]
    assert {:ok, _} = Nodes.restore(ctx.contributor, folder.id)
    assert {:ok, first} = Nodes.fetch(first.id)
    assert {:ok, second} = Nodes.fetch(second.id)
    assert is_nil(first.deleted_at) && is_nil(second.deleted_at)
    assert Enum.sort([first.name, second.name]) == ["report (1).txt", "report.txt"]
    assert {:ok, restricted} = Nodes.fetch(restricted.id)
    refute is_nil(restricted.deleted_at)
  end

  defp grant(actor, id) do
    assert :ok =
             Repo.transact_top_level(fn ->
               Nodes.lock_tree()

               Access.put_role(
                 %{principal_uid: actor.principal.uid},
                 "drive:**:#{id}:**",
                 "contribute"
               )
             end)
  end
end
