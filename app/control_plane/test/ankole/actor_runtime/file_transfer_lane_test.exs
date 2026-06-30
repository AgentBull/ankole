defmodule Ankole.ActorRuntime.FileTransferLaneTest do
  use Ankole.DataCase, async: false

  alias Ankole.ActorRuntime
  alias Ankole.ActorRuntime.FileTransferLane
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.Transport.Broker
  alias Ankole.Repo

  @credit_window 4 * 1024 * 1024

  setup do
    route = "file-lane-test-#{System.unique_integer([:positive])}"
    route_auth = %{route: route, worker_id: "worker-file-test", key_revision: 1}

    on_exit(fn -> Broker.unregister_local_worker(route) end)

    {:ok, route: route, route_auth: route_auth}
  end

  test "stat list move and delete use typed worker-file frames", %{
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

  test "put and get transfer zstd DATA chunks under credit", %{
    route: route,
    route_auth: route_auth
  } do
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil, read_wire: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_put_get(route_auth, stored, frames)
      end)

    assert {:ok,
            %{
              "command" => "WRITE_COMMITTED",
              "root" => "user_files",
              "relative_path" => "attachments/a.txt",
              "size" => 11,
              "xxh3_128" => "8db84f6b892cfa6bdad930c907ecb808"
            }} = FileTransferLane.put(route, "user_files", "attachments/a.txt", "hello world")

    compressed =
      Agent.get(stored, fn state -> state.chunks |> Enum.reverse() |> IO.iodata_to_binary() end)

    refute compressed == "hello world"
    assert Agent.get(stored, fn state -> zstd_decode_chunks!(state.chunks) end) == "hello world"

    assert {:ok,
            %{
              "content" => "hello world",
              "begin" => %{
                "command" => "READ_READY",
                "root" => "user_files",
                "relative_path" => "attachments/a.txt",
                "original_size" => 11,
                "content_encoding" => "zstd"
              },
              "end" => %{"command" => "READ_DONE", "chunks" => 1, "content_encoding" => "zstd"}
            }} = FileTransferLane.get(route, "user_files", "attachments/a.txt")
  end

  test "put and get preserve byte order across multiple compressed DATA chunks", %{
    route: route,
    route_auth: route_auth
  } do
    # Span more than one 2 MiB block so chunk ordering is exercised on both
    # write (control plane compresses per block) and read (worker compresses
    # per block). AAAAAA...BBBB... marker pattern catches any reversal.
    block_a = String.duplicate("A", 2 * 1024 * 1024)
    block_b = String.duplicate("B", 2 * 1024 * 1024)
    content = block_a <> block_b
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil, read_wire: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_put_get_large(route_auth, stored, content, frames)
      end)

    assert {:ok, %{"size" => size}} =
             FileTransferLane.put(route, "user_files", "attachments/large.bin", content)

    assert size == byte_size(content)

    assert Agent.get(stored, fn state -> length(state.chunks) end) >= 2

    assert Agent.get(stored, fn state -> zstd_decode_chunks!(state.chunks) end) == content

    assert {:ok, %{"content" => ^content}} =
             FileTransferLane.get(route, "user_files", "attachments/large.bin")
  end

  test "get rejects read terminators that do not match received DATA", %{
    route: route,
    route_auth: route_auth
  } do
    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_bad_read(route_auth, frames)
      end)

    assert {:error, :read_done_size_mismatch} =
             FileTransferLane.get(route, "user_files", "attachments/a.txt")
  end

  test "put timeout asks worker to abort the incomplete scratch transfer", %{
    route: route,
    route_auth: route_auth
  } do
    parent = self()

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_stalled_put(route_auth, parent, frames)
      end)

    assert {:error, :timeout} =
             FileTransferLane.put(route, "user_files", "attachments/slow.txt", "hello",
               timeout: 20
             )

    assert_receive {:file_lane_aborted, _transfer_id}, 100
  end

  test "get timeout asks worker to abort the active read stream", %{
    route: route,
    route_auth: route_auth
  } do
    parent = self()

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_stalled_read(route_auth, parent, frames)
      end)

    assert {:error, :timeout} =
             FileTransferLane.get(route, "user_files", "attachments/slow.txt", timeout: 20)

    assert_receive {:file_lane_read_aborted, _transfer_id}, 100
  end

  test "ActorRuntime.put_worker_file chooses a ready worker route", %{
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
             ActorRuntime.put_worker_file("user_files", "inbox/a.txt", "hello world")

    compressed =
      Agent.get(stored, fn state -> state.chunks |> Enum.reverse() |> IO.iodata_to_binary() end)

    refute compressed == "hello world"
    assert Agent.get(stored, fn state -> zstd_decode_chunks!(state.chunks) end) == "hello world"
  end

  test "responses from a different route do not satisfy a pending operation", %{
    route: route,
    route_auth: route_auth
  } do
    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane,
                                              [protocol, "STAT", transfer_id, _path, _fingerprint]} ->
        FileTransferLane.handle_worker_frame(
          %{route_auth | route: "different-route"},
          [
            protocol,
            "STAT_OK",
            transfer_id,
            "/user_files/inbox/message-1/hello.txt",
            "file",
            u64(4),
            u64(1),
            ""
          ]
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

  defp respond_to_filesystem_command(route_auth, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"STAT", [path, _fingerprint]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "STAT_OK",
          transfer_id,
          path,
          "file",
          u64(4),
          u64(1_772_000_000_000),
          "7b16fe7c3e492b87d9615265f0856cec"
        ])

      {"LIST", [path, recursive, _max_entries]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "LIST_OK",
          transfer_id,
          path,
          recursive,
          bool(false),
          entries_frame([
            %{
              relative_path: "inbox/message-1/hello.txt",
              kind: "file",
              size: 4,
              modified_unix_ms: 1_772_000_000_000
            }
          ])
        ])

      {"MOVE", [from_path, to_path, _overwrite]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "MOVE_OK",
          transfer_id,
          from_path,
          to_path
        ])

      {"DELETE", [path, _recursive]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "DELETE_OK",
          transfer_id,
          path
        ])
    end
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
          "8db84f6b892cfa6bdad930c907ecb808"
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

  defp respond_to_put_get_large(route_auth, stored, content, [
         protocol,
         command,
         transfer_id | rest
       ]) do
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
        {path, decoded} =
          Agent.get(stored, fn state ->
            {state.begin.path, zstd_decode_chunks!(state.chunks)}
          end)

        chunk_count = Agent.get(stored, fn state -> length(state.chunks) end)
        ^chunk_count = 2

        # Sanity: the worker-side decode recovers exactly the original content.
        ^decoded = content

        {path, decoded} =
          Agent.get(stored, fn state ->
            {state.begin.path, zstd_decode_chunks!(state.chunks)}
          end)

        chunk_count = Agent.get(stored, fn state -> length(state.chunks) end)
        ^chunk_count = 2

        # Sanity: the worker-side decode recovers exactly the original content.
        ^decoded = content

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "WRITE_COMMITTED",
          transfer_id,
          path,
          u64(byte_size(decoded)),
          "8db84f6b892cfa6bdad930c907ecb808"
        ])

      {"READ_OPEN", [path, _fingerprint]} ->
        # Compress content into one independent zstd frame per 2 MiB block and
        # send them back across DATA frames, mirroring the real worker.
        wire_chunks =
          content
          |> chunk_string(2 * 1024 * 1024)
          |> Enum.map(&zstd_encode!/1)

        Agent.update(stored, &%{&1 | read_wire: wire_chunks})

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_READY",
          transfer_id,
          path,
          u64(byte_size(content)),
          "8db84f6b892cfa6bdad930c907ecb808"
        ])

      {"CREDIT", [_credit]} ->
        wire_chunks = Agent.get(stored, & &1.read_wire)

        {data_frames, final_offset, chunk_count} =
          Enum.reduce(wire_chunks, {[], 0, 0}, fn chunk, {frames, offset, seq} ->
            eof = chunk == List.last(wire_chunks)

            frame =
              [protocol, "DATA", transfer_id, u64(seq), u64(offset), bool(eof), chunk]

            {[frame | frames], offset + byte_size(chunk), seq + 1}
          end)

        Enum.each(
          Enum.reverse(data_frames),
          &FileTransferLane.handle_worker_frame(route_auth, &1)
        )

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_DONE",
          transfer_id,
          u64(chunk_count),
          u64(final_offset)
        ])
    end
  end

  defp chunk_string(content, size) do
    chunk_string(content, size, [])
  end

  defp chunk_string(<<>>, _size, acc), do: Enum.reverse(acc)

  defp chunk_string(content, size, acc) do
    case byte_size(content) do
      n when n <= size ->
        Enum.reverse([content | acc])

      _ ->
        <<chunk::binary-size(^size), rest::binary>> = content
        chunk_string(rest, size, [chunk | acc])
    end
  end

  defp respond_to_bad_read(route_auth, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"READ_OPEN", [path, _fingerprint]} ->
        content = zstd_encode!("hello world")

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_READY",
          transfer_id,
          path,
          u64(12),
          ""
        ])

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

      {"CREDIT", [_credit]} ->
        :ok
    end
  end

  defp respond_to_stalled_put(route_auth, parent, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"WRITE_OPEN", [_path, _original_size]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "WRITE_READY",
          transfer_id,
          u64(@credit_window)
        ])

      {"DATA", [_sequence, _offset, _eof, chunk]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "CREDIT",
          transfer_id,
          u64(byte_size(chunk))
        ])

      {"WRITE_COMMIT", []} ->
        :ok

      {"WRITE_ABORT", []} ->
        send(parent, {:file_lane_aborted, transfer_id})
    end
  end

  defp respond_to_stalled_read(route_auth, parent, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"READ_OPEN", [path, _fingerprint]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_READY",
          transfer_id,
          path,
          u64(11),
          ""
        ])

      {"CREDIT", [_credit]} ->
        :ok

      {"READ_ABORT", []} ->
        send(parent, {:file_lane_read_aborted, transfer_id})
    end
  end

  defp insert_ready_worker!(route) do
    now = DateTime.utc_now(:microsecond)
    worker_id = "file-worker-#{System.unique_integer([:positive])}"

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
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
