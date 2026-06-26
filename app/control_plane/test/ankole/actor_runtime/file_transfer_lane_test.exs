defmodule Ankole.ActorRuntime.FileTransferLaneTest do
  use Ankole.DataCase, async: false

  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.FileTransferLane
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.Repo

  setup do
    route = "file-lane-test-#{System.unique_integer([:positive])}"
    route_auth = %{route: route, worker_id: "worker-file-test", key_revision: 1}

    on_exit(fn -> Broker.unregister_local_worker(route) end)

    {:ok, route: route, route_auth: route_auth}
  end

  test "stat list move and delete wait for worker responses", %{
    route: route,
    route_auth: route_auth
  } do
    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_filesystem_command(route_auth, frames)
      end)

    assert {:ok,
            %{
              "command" => "STAT",
              "root" => "user_files",
              "relative_path" => "inbox/message-1/hello.txt",
              "kind" => "file",
              "xxh3_128" => "7b16fe7c3e492b87d9615265f0856cec"
            }} =
             FileTransferLane.stat(route, "user_files", "inbox/message-1/hello.txt")

    assert {:ok,
            %{
              "command" => "LIST",
              "root" => "user_files",
              "relative_path" => "inbox",
              "recursive" => true,
              "entries" => [
                %{"relative_path" => "inbox/message-1/hello.txt", "kind" => "file"}
              ]
            }} = FileTransferLane.list(route, "user_files", "inbox", recursive: true)

    assert {:ok,
            %{
              "command" => "MOVE",
              "from_relative_path" => "inbox/message-1/hello.txt",
              "to_relative_path" => "archive/message-1/hello.txt",
              "moved" => true
            }} =
             FileTransferLane.move(
               route,
               "user_files",
               "inbox/message-1/hello.txt",
               "archive/message-1/hello.txt"
             )

    assert {:ok,
            %{
              "command" => "DELETE",
              "relative_path" => "archive/message-1/hello.txt",
              "deleted" => true
            }} = FileTransferLane.delete(route, "user_files", "archive/message-1/hello.txt")
  end

  test "put and get default to zstd raw binary chunks outside protobuf", %{
    route: route,
    route_auth: route_auth
  } do
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_put_get(route_auth, stored, frames)
      end)

    assert {:ok,
            %{
              "command" => "PUT_COMMIT",
              "root" => "user_files",
              "relative_path" => "attachments/a.txt",
              "size" => 11,
              "xxh3_128" => "8db84f6b892cfa6bdad930c907ecb808"
            }} = FileTransferLane.put(route, "user_files", "attachments/a.txt", "hello world")

    compressed =
      Agent.get(stored, fn state -> state.chunks |> Enum.reverse() |> IO.iodata_to_binary() end)

    refute compressed == "hello world"
    assert zstd_decode!(compressed) == "hello world"

    assert {:ok,
            %{
              "content" => "hello world",
              "begin" => %{
                "root" => "user_files",
                "relative_path" => "attachments/a.txt",
                "original_size" => 11
              },
              "end" => %{"chunks" => 1, "content_encoding" => "zstd"}
            }} = FileTransferLane.get(route, "user_files", "attachments/a.txt")
  end

  test "ActorRuntime.put_worker_file chooses a ready worker route", %{
    route: route,
    route_auth: route_auth
  } do
    insert_ready_worker!(route)
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_put_get(route_auth, stored, frames)
      end)

    assert {:ok, %{"command" => "PUT_COMMIT", "relative_path" => "inbox/a.txt"}} =
             ActorRuntime.put_worker_file("user_files", "inbox/a.txt", "hello world")

    compressed =
      Agent.get(stored, fn state -> state.chunks |> Enum.reverse() |> IO.iodata_to_binary() end)

    assert zstd_decode!(compressed) == "hello world"
  end

  test "put and get can explicitly use identity wire encoding", %{
    route: route,
    route_auth: route_auth
  } do
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_put_get(route_auth, stored, frames)
      end)

    assert {:ok, %{"command" => "PUT_COMMIT", "size" => 11}} =
             FileTransferLane.put(
               route,
               "user_files",
               "attachments/a.txt",
               "hello world",
               content_encoding: "identity"
             )

    raw_content =
      Agent.get(stored, fn state -> state.chunks |> Enum.reverse() |> IO.iodata_to_binary() end)

    assert raw_content == "hello world"

    assert {:ok, %{"content" => "hello world", "end" => %{"content_encoding" => "identity"}}} =
             FileTransferLane.get(
               route,
               "user_files",
               "attachments/a.txt",
               content_encoding: "identity"
             )
  end

  test "responses from a different route do not satisfy a pending operation", %{
    route: route,
    route_auth: route_auth
  } do
    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane,
                                              [protocol, "STAT", transfer_id, _metadata]} ->
        FileTransferLane.handle_worker_frame(
          %{route_auth | route: "different-route"},
          [protocol, "ACK", transfer_id, Torque.encode!(%{command: "STAT"})]
        )
      end)

    assert {:error, :timeout} =
             FileTransferLane.stat(route, "user_files", "inbox/message-1/hello.txt", timeout: 20)
  end

  test "unknown route is surfaced to callers" do
    assert {:error, :unknown_route} =
             FileTransferLane.stat(
               "missing-file-lane-route-#{System.unique_integer([:positive])}",
               "user_files",
               "a.txt",
               timeout: 20
             )
  end

  defp respond_to_filesystem_command(route_auth, [protocol, command, transfer_id, metadata_frame]) do
    metadata = Torque.decode!(metadata_frame)

    {response_command, payload} =
      case command do
        "STAT" ->
          {"ACK",
           %{
             command: "STAT",
             root: metadata["root"],
             relative_path: metadata["relative_path"],
             kind: "file",
             size: 4,
             modified_unix_ms: 1_772_000_000_000,
             xxh3_128: "7b16fe7c3e492b87d9615265f0856cec"
           }}

        "LIST" ->
          {"LIST_RESULT",
           %{
             command: "LIST",
             root: metadata["root"],
             relative_path: metadata["relative_path"],
             recursive: metadata["recursive"],
             entries: [
               %{
                 relative_path: "inbox/message-1/hello.txt",
                 kind: "file",
                 size: 4,
                 modified_unix_ms: 1_772_000_000_000
               }
             ],
             truncated: false
           }}

        "MOVE" ->
          {"ACK",
           %{
             command: "MOVE",
             root: metadata["root"],
             from_relative_path: metadata["from_relative_path"],
             to_relative_path: metadata["to_relative_path"],
             moved: true
           }}

        "DELETE" ->
          {"ACK",
           %{
             command: "DELETE",
             root: metadata["root"],
             relative_path: metadata["relative_path"],
             deleted: true
           }}
      end

    FileTransferLane.handle_worker_frame(route_auth, [
      protocol,
      response_command,
      transfer_id,
      Torque.encode!(payload)
    ])
  end

  defp respond_to_put_get(route_auth, stored, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"PUT_BEGIN", [metadata_frame]} ->
        metadata = Torque.decode!(metadata_frame)
        Agent.update(stored, &%{&1 | begin: metadata, chunks: []})
        send_ack(route_auth, protocol, transfer_id, %{command: "PUT_BEGIN"})

      {"PUT_CHUNK", [chunk_index, chunk]} ->
        Agent.update(stored, &%{&1 | chunks: [chunk | &1.chunks]})

        send_ack(route_auth, protocol, transfer_id, %{
          command: "PUT_CHUNK",
          chunk_index: String.to_integer(chunk_index)
        })

      {"PUT_COMMIT", []} ->
        payload =
          Agent.get(stored, fn state ->
            wire_content = state.chunks |> Enum.reverse() |> IO.iodata_to_binary()

            content =
              decode_put_content!(wire_content, state.begin["content_encoding"] || "zstd")

            %{
              command: "PUT_COMMIT",
              root: state.begin["root"],
              relative_path: state.begin["relative_path"],
              size: byte_size(content),
              xxh3_128: "8db84f6b892cfa6bdad930c907ecb808"
            }
          end)

        send_ack(route_auth, protocol, transfer_id, payload)

      {"GET", [metadata_frame]} ->
        metadata = Torque.decode!(metadata_frame)
        content_encoding = metadata["content_encoding"] || "zstd"
        content = encode_get_content!("hello world", content_encoding)

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "GET_BEGIN",
          transfer_id,
          Torque.encode!(%{
            root: metadata["root"],
            relative_path: metadata["relative_path"],
            original_size: 11,
            content_encoding: content_encoding,
            xxh3_128: "8db84f6b892cfa6bdad930c907ecb808"
          })
        ])

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "GET_CHUNK",
          transfer_id,
          "0",
          content
        ])

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "GET_END",
          transfer_id,
          Torque.encode!(%{chunks: 1, content_encoding: content_encoding})
        ])
    end
  end

  defp send_ack(route_auth, protocol, transfer_id, payload) do
    FileTransferLane.handle_worker_frame(route_auth, [
      protocol,
      "ACK",
      transfer_id,
      Torque.encode!(payload)
    ])
  end

  defp insert_ready_worker!(route) do
    now = DateTime.utc_now(:microsecond)
    worker_id = "file-worker-#{System.unique_integer([:positive])}"

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      worker_instance_id: "#{worker_id}-instance",
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })
  end

  defp encode_get_content!(content, "identity"), do: content
  defp encode_get_content!(content, "zstd"), do: zstd_encode!(content)

  defp decode_put_content!(content, "identity"), do: content
  defp decode_put_content!(content, "zstd"), do: zstd_decode!(content)

  defp zstd_encode!(content), do: run_zstd!(["-q", "-c"], content, "zstd encode")

  defp zstd_decode!(content), do: run_zstd!(["-q", "-d", "-c"], content, "zstd decode")

  defp run_zstd!(args, content, label) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ankole-file-lane-test-zstd-#{System.unique_integer([:positive])}"
      )

    try do
      File.write!(path, content)

      case System.cmd("zstd", args ++ [path], stderr_to_stdout: true) do
        {output, 0} -> output
        {output, status} -> flunk("#{label} failed with status #{status}: #{output}")
      end
    after
      File.rm(path)
    end
  end
end
