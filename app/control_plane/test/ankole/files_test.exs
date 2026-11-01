defmodule Ankole.FilesTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures
  alias Ankole.{Files, ObjectStore}
  alias Ankole.Files.Schemas.{FileObject, Node}

  setup do
    %{principal: agent} = agent_fixture()
    %{uid: agent.uid}
  end

  test "equal bytes create independent tenant objects and remain incomplete until referenced", %{
    uid: uid
  } do
    {:ok, first} = Files.store("same")
    {:ok, second} = Files.store("same")
    assert first.object_id != second.object_id
    assert first.sha256 == second.sha256
    assert {:error, :not_found} = Files.fetch_object(first.object_id)
    row = Repo.get_by!(FileObject, id: first.object_id)
    assert row.storage_key == "tenants/#{Repo.tenant_id!()}/objects/#{first.object_id}"
    assert row.completed_at == nil
    assert {:ok, "same"} = ObjectStore.read(row.storage_key)
    assert {:ok, %{files: [file]}} = Files.commit(uid, [Map.put(first, :path, "a.txt")])
    assert file.object_id == first.object_id
    assert {:ok, %{size: 4, completed_at: %DateTime{}}} = Files.fetch_object(first.object_id)
  end

  test "a streaming source is consumed once and stores its digest with the reference", %{uid: uid} do
    parent = self()

    source =
      Stream.map(["one", "two", "three"], fn chunk ->
        send(parent, {:chunk, chunk})
        chunk
      end)

    {:ok, stored} = Files.store(source)
    for part <- ["one", "two", "three"], do: assert_receive({:chunk, ^part})
    refute_receive {:chunk, _}
    assert {:ok, _} = Files.commit(uid, [Map.put(stored, :path, "stream.bin")])
    assert {:ok, object} = Files.fetch_object(stored.object_id)
    assert object.sha256 == :crypto.hash(:sha256, "onetwothree")
    assert {:ok, "twot"} = Files.read_object_range(object.id, 3, 4)
  end

  test "object ranges stop at EOF for stored prefixes, tails and empty files", %{uid: uid} do
    for content <- ["short UTF-8 文本", ""] do
      file = drive_file_fixture(uid, "range.txt", content)
      assert {:ok, object} = Files.fetch_object(file.object_id)
      assert {:ok, ^content} = Files.read_object_range(object.id, 0, 16_384)
      assert {:ok, ^content} = Files.read_object_range(object, 0, 16_384)
      assert {:ok, ""} = Files.read_object_range(object.id, byte_size(content), 100)
      assert {:ok, ""} = Files.read_object_range(object.id, byte_size(content) + 10, 100)
      assert {:ok, ""} = Files.read_object_range(object.id, 0, 0)
    end
  end

  test "overwriting preserves node identity and switches to a fresh immutable object", %{uid: uid} do
    first = drive_file_fixture(uid, "report.txt", "old")
    second = drive_file_fixture(uid, "report.txt", "new")
    assert first.id == second.id
    assert first.object_id != second.object_id
    assert {:ok, "old"} = Files.read_object(first.object_id)
    assert {:ok, %{object_id: id}, "new"} = Files.read(uid, "report.txt")
    assert id == second.object_id
    assert Repo.aggregate(from(n in Node, where: n.kind == :file), :count) == 1
  end

  test "the last committed close wins without changing either stored object", %{uid: uid} do
    file = drive_file_fixture(uid, "same.txt", "original")
    {:ok, first} = Files.store("first closer")
    {:ok, last} = Files.store("last closer")
    assert {:ok, _} = Files.commit(uid, [Map.put(first, :path, file.path)])
    assert {:ok, _} = Files.commit(uid, [Map.put(last, :path, file.path)])
    assert {:ok, %{id: id}, "last closer"} = Files.read(uid, file.path)
    assert id == file.id
    assert {:ok, "first closer"} = Files.read_object(first.object_id)
  end

  test "empty files and folders are distinct persisted nodes", %{uid: uid} do
    {:ok, root} = Files.private_root(uid)
    actor = actor_fixture(uid)
    {:ok, empty} = Files.create_node(actor, %{parent_id: root.id, kind: :file, name: "empty"})

    {:ok, _folder} =
      Files.create_node(actor, %{parent_id: root.id, kind: :folder, name: "folder"})

    assert {:ok, %{object_id: nil}, ""} = Files.read(uid, "empty")
    assert {:error, :not_a_file} = Files.read(uid, "folder")
    assert is_nil(Repo.get_by!(Node, id: empty.id).object_id)
  end

  test "one commit atomically creates folders, applies writes, and trashes removed nodes", %{
    uid: uid
  } do
    removed = drive_file_fixture(uid, "old/report.txt", "old")
    {:ok, stored} = Files.store("new")

    assert {:ok, %{files: [new], deleted: 1}} =
             Files.commit(uid, [Map.put(stored, :path, "new/report.txt")], ["old"])

    assert {:error, :not_found} = Files.fetch(uid, "old/report.txt")
    assert {:ok, %{object_id: id}, "new"} = Files.read(uid, new.path)
    assert id == stored.object_id
    assert {:ok, "old"} = Files.read_object(removed.object_id)
  end

  test "a rejected write rolls back the whole commit including deletes", %{uid: uid} do
    kept = drive_file_fixture(uid, "keep.txt", "keep")
    drive_file_fixture(uid, "ancestor", "file")
    {:ok, stored} = Files.store("child")

    assert {:error, :not_a_directory} =
             Files.commit(uid, [Map.put(stored, :path, "ancestor/child.txt")], ["keep.txt"])

    assert {:ok, %{id: id}, "keep"} = Files.read(uid, "keep.txt")
    assert id == kept.id
    assert {:error, :not_found} = Files.fetch_object(stored.object_id)
  end

  test "private paths and object IDs cannot resolve across tenants", %{uid: uid} do
    file = drive_file_fixture(uid, "private.txt", "private")
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      assert {:error, :not_found} = Files.fetch(uid, "private.txt")
      assert {:error, :not_found} = Files.fetch_object(file.object_id)
    end)
  end

  test "pagination and prefixes treat SQL wildcard characters literally", %{uid: uid} do
    for path <- ["a_/1", "a_/2", "a_/3", "aX/wrong", "p%/one", "pX/wrong"] do
      drive_file_fixture(uid, path)
    end

    assert {:ok, %{files: first, next_after: "a_/2"}} = Files.list(uid, "a_", limit: 2)
    assert Enum.map(first, & &1.path) == ["a_/1", "a_/2"]

    assert {:ok, %{files: [%{path: "a_/3"}], next_after: nil}} =
             Files.list(uid, "a_", limit: 2, after: "a_/2")

    assert {:ok, %{files: [%{path: "p%/one"}]}} = Files.list(uid, "p%")
  end

  test "moving a folder preserves its descendants' IDs and content", %{uid: uid} do
    file = drive_file_fixture(uid, "before/nested/a.txt", "value")
    assert {:ok, _} = Files.move(uid, "before", "after")
    assert {:error, :not_found} = Files.fetch(uid, file.path)
    assert {:ok, %{id: id}, "value"} = Files.read(uid, "after/nested/a.txt")
    assert id == file.id
  end

  test "snapshot revisions track object identity even for equal replacement bytes", %{uid: uid} do
    drive_file_fixture(uid, "skills/a", "equal")
    drive_file_fixture(uid, "skills/b", "other")
    {:ok, first} = Files.list(uid, "skills", limit: 1, snapshot: true)
    {:ok, next} = Files.list(uid, "skills", limit: 1, after: first.next_after, snapshot: true)
    assert first.revision == next.revision
    drive_file_fixture(uid, "skills/a", "equal")
    {:ok, changed} = Files.list(uid, "skills", snapshot: true)
    refute changed.revision == first.revision
  end

  test "GC deletes old unreferenced rows and enqueues durable byte deletion", %{uid: uid} do
    referenced = drive_file_fixture(uid, "kept.txt", "referenced")
    {:ok, orphan} = Files.store("incomplete orphan")
    {:ok, young} = Files.store("young")
    orphan_row = Repo.get_by!(FileObject, id: orphan.object_id)
    age([referenced.object_id, orphan.object_id])
    assert {:ok, 1} = Files.collect_objects()
    refute Repo.get_by(FileObject, id: orphan.object_id)
    assert Repo.get_by(FileObject, id: young.object_id)
    assert Repo.get_by(FileObject, id: referenced.object_id)

    assert_enqueued(
      worker: Files.Jobs.DeleteObject,
      args: %{"storage_key" => orphan_row.storage_key}
    )

    assert :ok = perform_job(Files.Jobs.DeleteObject, %{"storage_key" => orphan_row.storage_key})
    assert {:error, %{"code" => "not_found"}} = ObjectStore.read(orphan_row.storage_key)
  end

  test "trash keeps the current object referenced while replaced bytes become collectable", %{
    uid: uid
  } do
    old = drive_file_fixture(uid, "a.txt", "old")
    current = drive_file_fixture(uid, "a.txt", "current")
    assert {:ok, 1} = Files.delete(uid, "a.txt")
    age([old.object_id, current.object_id])
    assert {:ok, 1} = Files.collect_objects()
    assert {:error, :not_found} = Files.fetch_object(old.object_id)
    assert {:ok, "current"} = Files.read_object(current.object_id)
  end

  defp age(ids) do
    Repo.update_all(from(o in FileObject, where: o.id in ^ids),
      set: [created_at: DateTime.add(DateTime.utc_now(), -172_800)]
    )
  end
end
