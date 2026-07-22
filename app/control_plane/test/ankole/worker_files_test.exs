defmodule Ankole.WorkerFilesTest do
  use Ankole.DataCase, async: false

  alias Ankole.SignalsGateway.ActorRuntime.FileTransferLane
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.Repo
  alias Ankole.WorkerFiles

  @credit_window 4 * 1024 * 1024

  setup do
    route = "worker-files-test-#{System.unique_integer([:positive])}"
    route_auth = %{route: route, worker_id: "worker-files-test"}

    on_exit(fn -> Broker.unregister_local_worker(route) end)

    {:ok, route: route, route_auth: route_auth}
  end

  test "rejects roots outside the declared policy without touching a route" do
    assert {:error, {:unsupported_file_root, "shared_files"}} =
             WorkerFiles.get("shared_files", "a.txt")

    assert {:error, {:unsupported_file_root, "shared_files"}} =
             WorkerFiles.put("shared_files", "a.txt", "hello")

    assert {:error, {:unsupported_file_root, "shared_files"}} =
             WorkerFiles.list("shared_files", "")

    assert {:error, {:unsupported_file_root, "shared_files"}} =
             WorkerFiles.delete("shared_files", "a.txt")

    assert {:error, {:unsupported_file_root, "shared_files"}} =
             WorkerFiles.move("shared_files", "a.txt", "b.txt")
  end

  test "put rejects oversize content before any transfer starts" do
    max_bytes = WorkerFiles.max_transfer_bytes()
    oversize = max_bytes + 1
    content = :binary.copy(<<0>>, oversize)

    assert {:error, {:file_too_large, ^oversize, ^max_bytes}} =
             WorkerFiles.put("user_files", "inbox/huge.bin", content)
  end

  test "put chooses a ready worker route and round-trips bounded content", %{
    route: route,
    route_auth: route_auth
  } do
    insert_ready_worker!(route)
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil, read_wire: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_put_get(route_auth, stored, frames)
      end)

    assert {:ok, %{"command" => "WRITE_COMMITTED", "relative_path" => "inbox/a.txt"}} =
             WorkerFiles.put("user_files", "inbox/a.txt", "hello world")

    compressed =
      Agent.get(stored, fn state -> state.chunks |> Enum.reverse() |> IO.iodata_to_binary() end)

    refute compressed == "hello world"
    assert Agent.get(stored, fn state -> zstd_decode_chunks!(state.chunks) end) == "hello world"

    # The read side runs under the module's byte bound: READ_READY reports a
    # size below the bound, so credit is granted and content streams back.
    assert {:ok, %{"content" => "hello world"}} = WorkerFiles.get("user_files", "inbox/a.txt")
  end

  test "get rejects a file over max_transfer_bytes on READ_READY authoritative size", %{
    route: route,
    route_auth: route_auth
  } do
    insert_ready_worker!(route)
    parent = self()
    max_bytes = WorkerFiles.max_transfer_bytes()
    oversize = max_bytes + 1

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_oversize_read(route_auth, parent, oversize, frames)
      end)

    assert {:error, {:file_too_large, ^oversize, ^max_bytes}} =
             WorkerFiles.get("user_files", "inbox/huge.bin")

    assert_receive {:worker_files_read_aborted, _transfer_id}, 100
    refute_received {:worker_files_unexpected_credit, _transfer_id}
  end

  test "worker_id pins the route to that worker", %{route: route, route_auth: route_auth} do
    %{worker_id: worker_id} = insert_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_list(route_auth, frames)
      end)

    assert {:ok, %{"command" => "LIST", "root" => "agent_sessions"}} =
             WorkerFiles.list("agent_sessions", "agent-1/sessions", worker_id: worker_id)

    assert {:error, :worker_not_found} =
             WorkerFiles.list("agent_sessions", "agent-1/sessions", worker_id: "missing-worker")
  end

  test "Codex state is not exposed as a File Lane root" do
    refute "codex_accounts" in WorkerFiles.roots()

    assert {:error, {:unsupported_file_root, "codex_accounts"}} =
             WorkerFiles.get("codex_accounts", "account-1/auth.json")

    assert {:error, {:unsupported_file_root, "codex_accounts"}} =
             WorkerFiles.delete("codex_accounts", "account-1", recursive: true)
  end

  test "shared-route operations fail without a ready worker" do
    assert {:error, :no_worker_available} = WorkerFiles.get("user_files", "inbox/a.txt")
  end

  defp respond_to_list(route_auth, [protocol, "LIST", transfer_id, path, recursive, _max]) do
    FileTransferLane.handle_worker_frame(route_auth, [
      protocol,
      "LIST_OK",
      transfer_id,
      path,
      recursive,
      bool(false),
      entries_frame([])
    ])
  end

  defp respond_to_put_get(route_auth, stored, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"WRITE_OPEN", [path, original_size]} ->
        Agent.update(
          stored,
          &%{&1 | begin: %{path: path, original_size: parse_u64!(original_size)}, chunks: []}
        )

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "WRITE_READY",
          transfer_id,
          u64(@credit_window)
        ])

      {"DATA", [_sequence, _offset, _eof, chunk]} ->
        Agent.update(stored, &%{&1 | chunks: [chunk | &1.chunks]})

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "CREDIT",
          transfer_id,
          u64(byte_size(chunk))
        ])

      {"WRITE_COMMIT", []} ->
        {path, content} =
          Agent.get(stored, fn state ->
            {state.begin.path, zstd_decode_chunks!(state.chunks)}
          end)

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "WRITE_COMMITTED",
          transfer_id,
          path,
          u64(byte_size(content)),
          "8db84f6b892cfa6bdad930c907ecb808"
        ])

      {"READ_OPEN", [path, _fingerprint]} ->
        content = zstd_encode!("hello world")
        Agent.update(stored, &%{&1 | read_wire: content})

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_READY",
          transfer_id,
          path,
          u64(11),
          ""
        ])

      {"CREDIT", [_credit]} ->
        content = Agent.get(stored, & &1.read_wire)

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "DATA",
          transfer_id,
          u64(0),
          u64(0),
          bool(true),
          content
        ])

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_DONE",
          transfer_id,
          u64(1),
          u64(byte_size(content))
        ])
    end
  end

  defp respond_to_oversize_read(route_auth, parent, oversize, [
         protocol,
         command,
         transfer_id | rest
       ]) do
    case {command, rest} do
      {"READ_OPEN", [path, _fingerprint]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_READY",
          transfer_id,
          path,
          u64(oversize),
          ""
        ])

      {"CREDIT", [_credit]} ->
        send(parent, {:worker_files_unexpected_credit, transfer_id})

      {"READ_ABORT", []} ->
        send(parent, {:worker_files_read_aborted, transfer_id})
    end
  end

  defp insert_ready_worker!(route) do
    now = DateTime.utc_now(:microsecond)
    worker_id = "worker-files-worker-#{System.unique_integer([:positive])}"

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      incarnation_id: Ecto.UUID.generate(),
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

  defp u64(value), do: <<value::unsigned-big-integer-size(64)>>
  defp parse_u64!(<<value::unsigned-big-integer-size(64)>>), do: value
  defp bool(true), do: <<1>>
  defp bool(false), do: <<0>>

  defp entries_frame(entries) do
    [
      <<length(entries)::unsigned-big-integer-size(32)>>,
      Enum.map(entries, fn entry ->
        [
          sized_string(entry.relative_path),
          sized_string(entry.kind),
          u64(entry.size),
          u64(entry.modified_unix_ms)
        ]
      end)
    ]
    |> IO.iodata_to_binary()
  end

  defp sized_string(value) do
    value = IO.iodata_to_binary(value)
    <<byte_size(value)::unsigned-big-integer-size(32), value::binary>>
  end

  defp zstd_encode!(content) do
    compressed = Ankole.Kernel.zstd_compress_block(content, 3)
    true = is_binary(compressed)
    compressed
  end

  defp zstd_decode_chunks!(chunks) do
    # `chunks` is stored newest-first; iterate in stored order and prepend each
    # decoded block to recover the original oldest-first concatenation.
    Enum.reduce(chunks, [], fn chunk, acc ->
      decoded = Ankole.Kernel.zstd_decompress_block(chunk, 2 * 1024 * 1024)
      true = is_binary(decoded)
      [decoded | acc]
    end)
    |> IO.iodata_to_binary()
  end
end
