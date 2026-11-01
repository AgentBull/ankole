defmodule Ankole.Files.RPCBrokerTest do
  use Ankole.DataCase, async: true
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures
  alias Ankole.{Files, SessionsCase, WorkerFilesFake}
  alias Ankole.Files.RPCBroker
  alias Ankole.RuntimeFabric.V1, as: FabricProto

  setup do
    %{principal: agent} = agent_fixture()
    route = "files-broker-test-#{System.unique_integer([:positive])}"
    {:ok, _worker} = SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    %{
      uid: agent.uid,
      route: route,
      ctx: %{route: route, worker_id: agent.uid, request_id: "files-test"}
    }
  end

  test "lists stable node and object identities across pagination", %{uid: uid, ctx: ctx} do
    for name <- ["a.txt", "b.txt", "c.txt"], do: drive_file_fixture(uid, "docs/" <> name)

    assert {:ok, %{files: files, next_after: "docs/b.txt", revision: revision}} =
             RPCBroker.handle_list(
               uid,
               %FabricProto.FilesListRequest{prefix: "docs", limit: 2},
               ctx
             )

    assert Enum.map(files, & &1.path) == ["docs/a.txt", "docs/b.txt"]
    assert Enum.all?(files, &(is_binary(&1.node_id) and is_binary(&1.object_id)))
    assert byte_size(revision) == 64

    assert {:ok, %{files: [last], next_after: "", revision: ^revision}} =
             RPCBroker.handle_list(
               uid,
               %FabricProto.FilesListRequest{prefix: "docs", limit: 2, after: "docs/b.txt"},
               ctx
             )

    assert last.path == "docs/c.txt"
  end

  test "downloads a current authorized node into the calling Worker", %{
    uid: uid,
    route: route,
    ctx: ctx
  } do
    file = drive_file_fixture(uid, "report.txt", "bytes")
    worker = WorkerFilesFake.start!(route)

    assert {:ok, %{file: downloaded}} =
             RPCBroker.handle_get(
               uid,
               %FabricProto.FilesGetRequest{
                 node_id: file.id,
                 home_relative_path: "local/report.txt"
               },
               ctx
             )

    assert downloaded.node_id == file.id
    assert WorkerFilesFake.files(worker)["local/report.txt"] == "bytes"
  end

  test "path and node reads retain the executing Agent's conditional authentication context", %{
    uid: uid,
    route: route,
    ctx: ctx
  } do
    file = drive_file_fixture(uid, "conditional/secret.txt", "conditional bytes")
    worker = WorkerFilesFake.start!(route)

    assert :ok =
             Ankole.Repo.transact_top_level(fn ->
               Files.lock_tree_in_tx()
               {:ok, node} = Files.fetch_node(file.id)

               {:ok, _} =
                 Files.Access.update_anchor_in_tx(node, :sharing, %{inherit_permissions: false})

               Files.Access.put_role(
                 %{principal_uid: uid},
                 "drive:**:#{file.id}:node",
                 "view",
                 %{
                   condition:
                     ~s|has(context.request.authn.surface) && context.request.authn.surface == "agent_rpc"|
                 }
               )
             end)

    assert {:error, :forbidden} = Files.fetch(uid, file.path)
    assert {:ok, %{files: []}} = Files.list(uid, "conditional")
    assert {:error, :forbidden} = Files.authorize_node(actor_fixture(uid), file.id, "node_view")

    assert {:ok, %{files: [listed]}} =
             RPCBroker.handle_list(uid, %FabricProto.FilesListRequest{prefix: "conditional"}, ctx)

    assert listed.node_id == file.id

    for request <- [
          %FabricProto.FilesGetRequest{path: file.path, home_relative_path: "by-path.txt"},
          %FabricProto.FilesGetRequest{node_id: file.id, home_relative_path: "by-node.txt"}
        ] do
      assert {:ok, %{file: downloaded}} = RPCBroker.handle_get(uid, request, ctx)
      assert downloaded.node_id == file.id
      assert WorkerFilesFake.files(worker)[request.home_relative_path] == "conditional bytes"
    end
  end

  test "rejects another Agent's private node", %{uid: uid, ctx: ctx} do
    %{principal: other} = agent_fixture()
    file = drive_file_fixture(other.uid, "private.txt", "private")

    assert {:error, %{"code" => "forbidden"}} =
             RPCBroker.handle_get(
               uid,
               %FabricProto.FilesGetRequest{node_id: file.id, home_relative_path: "stolen.txt"},
               ctx
             )
  end

  test "streams every write once and never deduplicates by digest", %{
    uid: uid,
    route: route,
    ctx: ctx
  } do
    worker = WorkerFilesFake.start!(route, files: %{"local/a" => "same", "local/b" => "same"})

    request = %FabricProto.FilesCommitRequest{
      upserts: [upsert("a", "local/a", "same"), upsert("b", "local/b", "same")]
    }

    assert {:ok, %{files: [a, b]}} = RPCBroker.handle_commit(uid, request, ctx)
    assert a.object_id != b.object_id
    assert a.sha256 == b.sha256
    assert length(WorkerFilesFake.pushes(worker)) == 2
    assert Enum.all?(WorkerFilesFake.pushes(worker), &(&1.bundle_paths == []))
    assert {:ok, _, "same"} = Files.read(uid, "a")
    assert {:ok, _, "same"} = Files.read(uid, "b")
  end

  test "rejects digest and size mismatches before committing references", %{
    uid: uid,
    route: route,
    ctx: ctx
  } do
    WorkerFilesFake.start!(route, files: %{"local/file" => "actual"})

    assert {:error, %{"code" => "sha256_mismatch"}} =
             RPCBroker.handle_commit(
               uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [upsert("bad", "local/file", "expected")]
               },
               ctx
             )

    assert {:error, :not_found} = Files.fetch(uid, "bad")

    assert {:error, %{"code" => "file_size_mismatch"}} =
             RPCBroker.handle_commit(
               uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [%{upsert("bad", "local/file", "actual") | size: 99}]
               },
               ctx
             )

    assert {:error, :not_found} = Files.fetch(uid, "bad")
  end

  test "preserves Worker failures and commits no node on relay failure", %{
    uid: uid,
    route: route,
    ctx: ctx
  } do
    WorkerFilesFake.start!(route, fail: %{"push" => {"file_not_found", "missing source"}})

    assert {:error, %{"code" => "file_not_found"}} =
             RPCBroker.handle_commit(
               uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [upsert("missing", "local/missing", "missing")]
               },
               ctx
             )

    assert {:error, :not_found} = Files.fetch(uid, "missing")
  end

  defp upsert(path, local, content),
    do: %FabricProto.FilesCommitUpsert{
      path: path,
      home_relative_path: local,
      size: byte_size(content),
      sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    }
end
