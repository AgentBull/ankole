defmodule Ankole.Files.NodesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{Files, Repo}
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Pod.{Pages, Properties}

  setup do
    owner = human_fixture().principal
    contributor = human_fixture().principal
    {:ok, root} = Nodes.private_root(owner.uid)
    %{owner: actor_fixture(owner), contributor: actor_fixture(contributor), root: root}
  end

  test "folder contributors create and initially fill files but cannot overwrite or rename",
       ctx do
    {:ok, folder} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :folder, name: "Inbox"})

    grant(ctx.contributor, folder.id)

    assert {:ok, file} =
             Nodes.create(ctx.contributor, %{parent_id: folder.id, kind: :file, name: "notes.txt"})

    assert {:ok, _} = Files.write_node(ctx.contributor, file.id, "first")
    assert {:ok, current} = Nodes.fetch(file.id)
    assert {:ok, "first"} = Files.read_object(current.object_id)
    assert {:error, :forbidden} = Files.write_node(ctx.contributor, file.id, "replacement")
    assert {:error, :forbidden} = Nodes.rename(ctx.contributor, file.id, "changed.txt")
    assert {:error, :forbidden} = Nodes.trash(ctx.contributor, file.id)

    assert {:ok, %{kind: :folder}} =
             Nodes.create(ctx.contributor, %{
               parent_id: folder.id,
               kind: :folder,
               name: "Subdirectory"
             })
  end

  test "ACL maintenance preserves modification time while node mutations advance it", ctx do
    {:ok, folder} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :folder, name: "Inbox"})

    {:ok, file} = Nodes.create(ctx.owner, %{parent_id: folder.id, kind: :file, name: "File"})
    grant(ctx.contributor, folder.id)
    assert {:ok, anchored} = Nodes.fetch(folder.id)
    assert anchored.updated_at == folder.updated_at
    assert {:ok, reanchored} = Nodes.fetch(file.id)
    assert reanchored.updated_at == file.updated_at

    assert {:ok, _} = Files.write_node(ctx.owner, file.id, "content")
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
               kind: :file,
               name: "denied.txt"
             })

    {:ok, empty} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :file, name: "prepared.txt"})

    assert {:ok, _} = Files.write_node(ctx.contributor, empty.id, "initial")
    assert {:error, :forbidden} = Files.write_node(ctx.contributor, empty.id, "overwrite")
  end

  test "names deduplicate and restoring avoids occupied live names", ctx do
    attrs = %{parent_id: ctx.root.id, kind: :file, name: "report.txt"}
    {:ok, first} = Nodes.create(ctx.owner, attrs)
    {:ok, second} = Nodes.create(ctx.owner, attrs)
    assert second.name == "report.txt (1)"
    assert {:ok, _} = Nodes.trash(ctx.owner, first.id)
    assert {:ok, %{name: "report.txt"}} = Nodes.create(ctx.owner, attrs)
    assert {:ok, %{name: "report.txt (2)"}} = Nodes.restore(ctx.owner, first.id)

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

  test "legacy Bidi-named nodes remain readable, movable without rename, trashable, and converge on rename",
       ctx do
    {:ok, folder} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :folder, name: "Archive"})

    {:ok, file} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :file, name: "placeholder.sh"})

    assert {:ok, _} = Files.write_node(ctx.owner, file.id, "echo legacy")

    legacy_name = "报价单_\u202Efdp.sh"

    Repo.query!(
      "UPDATE drive_nodes SET name = $1 WHERE tenant_id = $2::text::uuid AND id = $3::text::uuid",
      [legacy_name, Repo.tenant_id!(), file.id]
    )

    assert {:ok, %{name: ^legacy_name}} = Nodes.fetch(file.id)
    assert {:ok, _meta, "echo legacy"} = Files.read(ctx.owner.principal.uid, legacy_name)
    assert {:error, :invalid_name} = Nodes.rename(ctx.owner, file.id, legacy_name)
    assert {:ok, moved} = Nodes.move(ctx.owner, file.id, %{parent_id: folder.id})
    assert moved.parent_id == folder.id
    assert {:ok, renamed} = Nodes.rename(ctx.owner, file.id, Files.file_name(legacy_name))
    assert renamed.name == "报价单_fdp.sh"
    assert {:ok, _} = Nodes.trash(ctx.owner, file.id)
  end

  test "name allocation probes a candidate without loading its siblings", ctx do
    attrs = %{parent_id: ctx.root.id, kind: :file, name: "report.txt"}
    {:ok, first} = Nodes.create(ctx.owner, attrs)
    {:ok, second} = Nodes.create(ctx.owner, attrs)
    assert Nodes.available_name(ctx.root.id, first.name, first.id) == first.name
    assert Nodes.available_name(ctx.root.id, first.name, second.id) == second.name

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
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :folder, name: "Folder"})

    {:ok, file} = Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :file, name: "File"})
    assert is_nil(Repo.get_by(Properties, id: file.id))
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
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :folder, name: "Folder"})

    {:ok, file} = Nodes.create(ctx.owner, %{parent_id: folder.id, kind: :file, name: "File"})
    assert {:ok, _} = Nodes.trash(ctx.owner, folder.id)
    assert {:error, :not_found} = Files.write_node(ctx.owner, file.id, "hidden")

    assert {:error, :not_found} =
             Nodes.create(ctx.owner, %{parent_id: folder.id, kind: :file, name: "Other"})
  end

  test "an isolated manage grant does not permit changing a file name", ctx do
    {:ok, file} =
      Nodes.create(ctx.owner, %{parent_id: ctx.root.id, kind: :file, name: "Original"})

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
    assert :ok = Ankole.Files.Jobs.PurgeNode.run(%Oban.Job{args: %{"node_id" => page.id}})
    assert exists.() == [[false]]
    assert {:error, :not_found} = Nodes.fetch(page.id)
    refute Repo.get_by(Ankole.Pod.BaseTable, id: table.id)
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
