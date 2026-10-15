defmodule Ankole.Files.RPCBrokerTest do
  use Ankole.DataCase, async: true

  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.Files
  alias Ankole.Files.RPCBroker
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SessionsCase
  alias Ankole.WorkerFiles
  alias Ankole.WorkerFilesFake

  setup do
    %{principal: agent} = agent_fixture()
    route = "files-broker-test-#{System.unique_integer([:positive])}"
    {:ok, _worker} = SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    %{
      agent_uid: agent.uid,
      route: route,
      ctx: %{route: route, worker_id: agent.uid, request_id: "files-test"}
    }
  end

  test "lists a folder in pages", %{agent_uid: agent_uid, ctx: ctx} do
    for name <- ["a.txt", "b.txt", "c.txt"], do: drive_file_fixture(agent_uid, "docs/" <> name)

    assert {:ok,
            %FabricProto.FilesListResponse{
              files: page,
              next_after: "docs/b.txt",
              revision: revision
            }} =
             RPCBroker.handle_list(
               agent_uid,
               %FabricProto.FilesListRequest{prefix: "docs", limit: 2},
               ctx
             )

    assert Enum.map(page, & &1.path) == ["docs/a.txt", "docs/b.txt"]
    assert byte_size(revision) == 64

    assert {:ok,
            %FabricProto.FilesListResponse{files: [last], next_after: "", revision: ^revision}} =
             RPCBroker.handle_list(
               agent_uid,
               %FabricProto.FilesListRequest{prefix: "docs", limit: 2, after: "docs/b.txt"},
               ctx
             )

    assert last.path == "docs/c.txt"
  end

  test "returns public conversation and message IDs in file listings", %{
    agent_uid: agent_uid,
    ctx: ctx
  } do
    %{message: message} =
      Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid)
      |> then(fn signal ->
        Ankole.Conversations.External.get_message(
          Ankole.Repo,
          signal.conversation_id,
          signal.provider_message_id
        )
      end)

    {:ok, %{sha256: sha256}} = Files.store("origin")

    assert {:ok, _} =
             Files.commit(agent_uid, [
               %{
                 path: "inbox/origin.txt",
                 sha256: sha256,
                 source: "inbound",
                 conversation_id: message.conversation_id,
                 message_id: message.id
               }
             ])

    assert {:ok, %FabricProto.FilesListResponse{files: [file]}} =
             RPCBroker.handle_list(
               agent_uid,
               %FabricProto.FilesListRequest{},
               ctx
             )

    assert file.conversation_id == message.conversation_id
    assert file.message_id == message.id
  end

  test "writes a drive file into the Agent Home of the calling Worker", %{
    agent_uid: agent_uid,
    route: route,
    ctx: ctx
  } do
    file = drive_file_fixture(agent_uid, "inbox/abc/photo.png", "png bytes", "inbound")
    fake = WorkerFilesFake.start!(route)

    assert {:ok, %FabricProto.FilesGetResponse{file: wire}} =
             RPCBroker.handle_get(
               agent_uid,
               %FabricProto.FilesGetRequest{
                 path: file.path,
                 home_relative_path: "sessions/10000/drive/inbox/abc/photo.png"
               },
               ctx
             )

    assert wire.sha256 == Base.encode16(file.sha256, case: :lower)

    assert WorkerFilesFake.files(fake) == %{
             "sessions/10000/drive/inbox/abc/photo.png" => "png bytes"
           }

    assert {:error, %{"code" => "not_found"}} =
             RPCBroker.handle_get(
               agent_uid,
               %FabricProto.FilesGetRequest{path: "inbox/missing.png", home_relative_path: "x"},
               ctx
             )
  end

  test "keeps the code of a Worker error", %{agent_uid: agent_uid, route: route, ctx: ctx} do
    file = drive_file_fixture(agent_uid, "docs/a.txt", "a")
    WorkerFilesFake.start!(route, fail: %{"pull" => {"path_outside_home", "outside"}})

    assert {:error, %{"code" => "path_outside_home", "message" => "outside"}} =
             RPCBroker.handle_get(
               agent_uid,
               %FabricProto.FilesGetRequest{path: file.path, home_relative_path: "docs/a.txt"},
               ctx
             )
  end

  test "commits a file pulled from the calling Worker and names sent copies as sent", %{
    agent_uid: agent_uid,
    route: route,
    ctx: ctx
  } do
    WorkerFilesFake.start!(route,
      files: %{"sessions/10000/out/report.txt" => "report body"}
    )

    sha256 = Base.encode16(:crypto.hash(:sha256, "report body"), case: :lower)

    assert {:ok, %FabricProto.FilesCommitResponse{files: [saved], deleted: 0}} =
             RPCBroker.handle_commit(
               agent_uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [
                   %FabricProto.FilesCommitUpsert{
                     path: "reports/report.txt",
                     home_relative_path: "sessions/10000/out/report.txt",
                     sha256: sha256
                   }
                 ]
               },
               ctx
             )

    assert {saved.source, saved.sha256} == {"agent", sha256}

    # A reply attachment pins a drive file under sent/ by digest alone.
    assert {:ok, %FabricProto.FilesCommitResponse{files: [sent]}} =
             RPCBroker.handle_commit(
               agent_uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [
                   %FabricProto.FilesCommitUpsert{
                     path: "sent/#{String.slice(sha256, 0, 16)}/report.txt",
                     sha256: sha256
                   }
                 ]
               },
               ctx
             )

    assert {sent.source, sent.sha256} == {"sent", sha256}
    assert {:ok, _file, "report body"} = Files.read(agent_uid, "reports/report.txt")
  end

  test "skips the transfer for content that the Agent's drive already names", %{
    agent_uid: agent_uid,
    route: route,
    ctx: ctx
  } do
    file = drive_file_fixture(agent_uid, "a.txt", "known")
    sha256 = Base.encode16(file.sha256, case: :lower)
    WorkerFilesFake.start!(route, fail: %{"push" => {"file_not_found", "no transfer expected"}})

    assert {:ok, %FabricProto.FilesCommitResponse{files: [copy]}} =
             RPCBroker.handle_commit(
               agent_uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [
                   %FabricProto.FilesCommitUpsert{
                     path: "b.txt",
                     home_relative_path: "local/b.txt",
                     sha256: sha256
                   }
                 ]
               },
               ctx
             )

    assert copy.path == "b.txt"
  end

  test "rejects a pulled file whose digest differs from the declared one", %{
    agent_uid: agent_uid,
    route: route,
    ctx: ctx
  } do
    WorkerFilesFake.start!(route, files: %{"local/c.txt" => "actual"})

    assert {:error, %{"code" => "sha256_mismatch"}} =
             RPCBroker.handle_commit(
               agent_uid,
               %FabricProto.FilesCommitRequest{
                 upserts: [
                   %FabricProto.FilesCommitUpsert{
                     path: "c.txt",
                     home_relative_path: "local/c.txt",
                     sha256: String.duplicate("ab", 32)
                   }
                 ]
               },
               ctx
             )

    assert {:error, :not_found} = Files.fetch(agent_uid, "c.txt")
  end

  test "bundles the missing files of one folder and transfers a repeated content once", %{
    agent_uid: agent_uid,
    route: route,
    ctx: ctx
  } do
    contents = [
      {"jobs/7/a.txt", "same"},
      {"jobs/7/copy.txt", "same"},
      {"jobs/7/sub/b.txt", "bee"},
      {"notes.txt", "top"}
    ]

    fake =
      WorkerFilesFake.start!(route,
        files:
          Map.new(contents, fn {path, content} ->
            {path, content}
          end)
      )

    assert {:ok, %FabricProto.FilesCommitResponse{files: files}} =
             RPCBroker.handle_commit(
               agent_uid,
               %FabricProto.FilesCommitRequest{
                 upserts: Enum.map(contents, fn {path, content} -> upsert(path, content) end)
               },
               ctx
             )

    assert Enum.map(files, & &1.path) == Enum.map(contents, &elem(&1, 0))

    assert Enum.sort_by(WorkerFilesFake.pushes(fake), & &1.home_relative_path) == [
             %{home_relative_path: "jobs", bundle_paths: ["7/a.txt", "7/sub/b.txt"]},
             %{home_relative_path: "notes.txt", bundle_paths: []}
           ]

    for {path, content} <- contents,
        do: assert({:ok, _file, ^content} = Files.read(agent_uid, path))
  end

  test "keeps every bundle within the transfer bound by the declared sizes", %{
    agent_uid: agent_uid,
    route: route,
    ctx: ctx
  } do
    half = div(WorkerFiles.max_transfer_bytes(), 2)

    contents = [
      {"jobs/7/a.txt", "a", half},
      {"jobs/7/b.txt", "b", half},
      {"jobs/7/c.txt", "c", 1}
    ]

    fake =
      WorkerFilesFake.start!(route,
        files:
          Map.new(contents, fn {path, content, _size} ->
            {path, content}
          end)
      )

    assert {:ok, %FabricProto.FilesCommitResponse{files: [_, _, _]}} =
             RPCBroker.handle_commit(
               agent_uid,
               %FabricProto.FilesCommitRequest{
                 upserts:
                   Enum.map(contents, fn {path, content, size} ->
                     %{upsert(path, content) | size: size}
                   end)
               },
               ctx
             )

    assert WorkerFilesFake.pushes(fake) == [
             %{home_relative_path: "jobs/7/a.txt", bundle_paths: []},
             %{home_relative_path: "jobs", bundle_paths: ["7/b.txt", "7/c.txt"]}
           ]
  end

  defp upsert(path, content) do
    %FabricProto.FilesCommitUpsert{
      path: path,
      home_relative_path: path,
      sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower),
      size: byte_size(content)
    }
  end
end
