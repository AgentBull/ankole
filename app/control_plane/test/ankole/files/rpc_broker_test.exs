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
               Ankole.Pod.lock_tree_in_tx()
               {:ok, node} = Ankole.Pod.fetch_node(file.id)

               {:ok, _} =
                 Ankole.Pod.Access.update_anchor_in_tx(node, :sharing, %{
                   inherit_permissions: false
                 })

               Ankole.Pod.Access.put_role(
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

    assert {:error, :forbidden} =
             Ankole.Pod.authorize_node(actor_fixture(uid), file.id, "node_view")

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

  test "office file downloads by node and path flush pending edits through the relay", %{
    uid: uid,
    route: route,
    ctx: ctx
  } do
    file = drive_file_fixture(uid, "forecast.xlsx", workbook("Forecast"))
    worker = WorkerFilesFake.start!(route)
    actor = actor_fixture(uid)

    for {selector, cell, value, text} <- [
          {%{node_id: file.id}, "B2", "12500", "[Sheet: Sheet1]\nR1\tForecast\nR2\t\t12500\n"},
          {%{path: file.path}, "C2", "=B2*1.2",
           "[Sheet: Sheet1]\nR1\tForecast\nR2\t\t12500\t15000\n"}
        ] do
      {:ok, %{revision: revision}} = Ankole.Pod.OfficeFiles.bootstrap(actor, file.id)

      assert {:ok, _} =
               Ankole.Pod.OfficeFiles.apply_op(actor, file.id, %{
                 base_revision: revision,
                 client_id: "forecast-editor",
                 client_seq: revision + 1,
                 op: %{"type" => "cell.set", "sheet_id" => 1, "cell" => cell, "input" => value}
               })

      request =
        struct(
          FabricProto.FilesGetRequest,
          Map.put(selector, :home_relative_path, "forecast.xlsx")
        )

      assert {:ok, %{file: downloaded}} = RPCBroker.handle_get(uid, request, ctx)
      bytes = WorkerFilesFake.files(worker)["forecast.xlsx"]
      assert downloaded.sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      assert {:ok, %{plain_text: ^text}} = Ankole.Kernel.office_open(:spreadsheet, bytes, [])

      {:ok, entries} = :zip.extract(bytes, [:memory])
      {_, sheet} = List.keyfind(entries, ~c"xl/worksheets/sheet1.xml", 0)
      {xml, _} = :xmerl_scan.string(String.to_charlist(sheet))

      assert {:xmlObj, :number, budget} =
               :xmerl_xpath.string(
                 ~c"number(//*[local-name()='c'][@r='B2']/*[local-name()='v'])",
                 xml
               )

      assert budget == 12_500

      if cell == "C2" do
        assert {:xmlObj, :number, forecast} =
                 :xmerl_xpath.string(
                   ~c"number(//*[local-name()='c'][@r='C2']/*[local-name()='v'])",
                   xml
                 )

        assert forecast == 15_000
      end

      assert {:ok, %{ops: []}} = Ankole.Pod.OfficeFiles.bootstrap(actor, file.id)
    end
  end

  test "an office file commit relays replacement bytes and resets an editor's pending log", %{
    uid: uid,
    route: route,
    ctx: ctx
  } do
    file = drive_file_fixture(uid, "forecast.xlsx", workbook("Original forecast"))
    replacement = workbook("Revised forecast")
    WorkerFilesFake.start!(route, files: %{"revised.xlsx" => replacement})
    actor = actor_fixture(uid)
    {:ok, %{revision: revision}} = Ankole.Pod.OfficeFiles.bootstrap(actor, file.id)

    assert {:ok, %{revision: edited_revision}} =
             Ankole.Pod.OfficeFiles.apply_op(actor, file.id, %{
               base_revision: revision,
               client_id: "forecast-editor",
               client_seq: 1,
               op: %{"type" => "cell.set", "sheet_id" => 1, "cell" => "B2", "input" => "pending"}
             })

    assert {:ok, %{files: [committed]}} =
             RPCBroker.handle_commit(
               uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [upsert(file.path, "revised.xlsx", replacement)]
               },
               ctx
             )

    assert committed.node_id == file.id

    assert {:ok, %{ops: [], file: %{object_id: object_id}}} =
             Ankole.Pod.OfficeFiles.bootstrap(actor, file.id)

    assert object_id == committed.object_id
    assert {:ok, ^replacement} = Files.read_object(object_id)

    assert {:ok, %{reset_required: true, changes: [%{kind: :reset}]}} =
             Ankole.Pod.OfficeFiles.since(actor, file.id, edited_revision)
  end

  defp workbook(label) do
    {:ok, %{doc_ref: document}} = Ankole.Kernel.office_create_blank(:spreadsheet, "Forecast")

    {:ok, %{doc_ref: document}} =
      Ankole.Kernel.office_apply(
        document,
        %{"type" => "cell.set", "sheet_id" => 1, "cell" => "A1", "input" => label},
        [],
        nil
      )

    {:ok, %{bytes: bytes}} = Ankole.Kernel.office_export(document)
    bytes
  end

  defp upsert(path, local, content),
    do: %FabricProto.FilesCommitUpsert{
      path: path,
      home_relative_path: local,
      size: byte_size(content),
      sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    }
end
