defmodule AnkoleWeb.WorkerFileControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.SignalsGateway.ActorRuntime.FileTransferLane
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  @credit_window 4 * 1024 * 1024

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    route = "worker-file-test-#{System.unique_integer([:positive])}"
    route_auth = %{route: route, worker_id: "worker-file-controller", key_revision: 1}

    on_exit(fn -> Broker.unregister_local_worker(route) end)

    {:ok, route: route, route_auth: route_auth}
  end

  test "OpenAPI JSON includes worker file endpoints", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/openapi.json")
    paths = json_response(conn, 200)["paths"]

    assert Map.has_key?(paths, "/api/v1/agent-computer-workers/{worker_id}/files")
  end

  test "list returns entries and truncation from the lane", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_filesystem_command(route_auth, frames)
      end)

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=workspace_sessions&path=agent-1"
      )

    assert %{
             "data" => %{
               "root" => "workspace_sessions",
               "path" => "agent-1",
               "truncated" => false,
               "entries" => [entry]
             }
           } = json_response(conn, 200)

    assert entry["relative_path"] == "agent-1/session-1/log.txt"
    assert entry["kind"] == "file"
    assert entry["size"] == 4
  end

  test "upload writes a file and returns size and relative path", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_put(route_auth, stored, frames)
      end)

    upload = build_upload!("hello world")

    conn =
      bearer_conn(conn)
      |> multipart(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files",
        root: "workspace_sessions",
        path: "agent-1/session-1/inbox/note.txt",
        file: upload
      )

    assert %{
             "data" => %{
               "root" => "workspace_sessions",
               "relative_path" => "agent-1/session-1/inbox/note.txt",
               "size" => 11
             }
           } = json_response(conn, 200)
  end

  test "download streams file content with content-disposition", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)
    {:ok, stored} = Agent.start_link(fn -> %{chunks: [], begin: nil, read_wire: nil} end)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_get(route_auth, stored, frames)
      end)

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files/content?root=user_files&path=attachments/hello world.txt"
      )

    assert response(conn, 200) == "hello world"

    assert Plug.Conn.get_resp_header(conn, "content-disposition") |> List.first() =~
             "hello%20world.txt"

    assert Plug.Conn.get_resp_header(conn, "content-type") |> List.first() =~
             "application/octet-stream"
  end

  test "download maps a worker read error for a directory path to 404", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_with_error(
          route_auth,
          frames,
          "operation_failed",
          "not a regular file: /workspace_sessions/agent-1"
        )
      end)

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files/content?root=workspace_sessions&path=agent-1"
      )

    assert %{"error" => %{"code" => "worker_file_error"}} = json_response(conn, 404)
  end

  test "download surfaces file_too_large from the READ_READY authoritative size", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_large_file(route_auth, frames)
      end)

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files/content?root=user_files&path=big.bin"
      )

    assert %{"error" => %{"code" => "file_too_large"}} = json_response(conn, 422)
  end

  test "move renames a path", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_filesystem_command(route_auth, frames)
      end)

    conn =
      bearer_conn(conn)
      |> post(~p"/api/v1/agent-computer-workers/#{worker_id}/file-moves", %{
        "root" => "user_files",
        "from_path" => "inbox/message-1/hello.txt",
        "to_path" => "archive/message-1/hello.txt",
        "overwrite" => false
      })

    assert %{
             "data" => %{
               "root" => "user_files",
               "from_relative_path" => "inbox/message-1/hello.txt",
               "to_relative_path" => "archive/message-1/hello.txt",
               "moved" => true
             }
           } = json_response(conn, 200)
  end

  test "delete removes a path", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_filesystem_command(route_auth, frames)
      end)

    conn =
      bearer_conn(conn)
      |> delete(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=user_files&path=archive/message-1/hello.txt&recursive=true"
      )

    assert %{
             "data" => %{
               "root" => "user_files",
               "relative_path" => "archive/message-1/hello.txt",
               "deleted" => true
             }
           } = json_response(conn, 200)
  end

  test "unknown worker returns 404 worker_not_found", %{conn: conn} do
    conn =
      bearer_conn(conn)
      |> get(~p"/api/v1/agent-computer-workers/missing-worker/files?root=workspace_sessions")

    assert %{"error" => %{"code" => "worker_not_found"}} = json_response(conn, 404)
  end

  test "stale worker returns 409 worker_not_ready", %{
    conn: conn,
    route: route
  } do
    %{worker_id: worker_id} = register_worker!(route, "stale")

    conn =
      bearer_conn(conn)
      |> get(~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=workspace_sessions")

    assert %{"error" => %{"code" => "worker_not_ready"}} = json_response(conn, 409)
  end

  test "worker ERROR frame in list maps to 404", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_with_error(route_auth, frames, "ENOENT", "path does not exist")
      end)

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=workspace_sessions&path=missing"
      )

    assert %{"error" => %{"code" => "worker_file_error", "message" => "path does not exist"}} =
             json_response(conn, 404)
  end

  test "worker ERROR frame in move maps to 422", %{
    conn: conn,
    route: route,
    route_auth: route_auth
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_with_error(route_auth, frames, "EEXIST", "target exists")
      end)

    conn =
      bearer_conn(conn)
      |> post(~p"/api/v1/agent-computer-workers/#{worker_id}/file-moves", %{
        "root" => "user_files",
        "from_path" => "a.txt",
        "to_path" => "b.txt"
      })

    assert %{"error" => %{"code" => "worker_file_error"}} = json_response(conn, 422)
  end

  test "invalid root is rejected by cast and validate", %{
    conn: conn,
    route: route
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    conn =
      bearer_conn(conn)
      |> get(~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=shared_files")

    assert conn.status == 422
  end

  # --- fake worker responders (mirror file_transfer_lane_test helpers) ---

  defp respond_to_filesystem_command(route_auth, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
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
              relative_path: "agent-1/session-1/log.txt",
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

  defp respond_to_large_file(route_auth, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"READ_OPEN", [path, _fingerprint]} ->
        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "READ_READY",
          transfer_id,
          path,
          u64(200 * 1024 * 1024),
          ""
        ])

      {"READ_ABORT", []} ->
        :ok
    end
  end

  defp respond_with_error(route_auth, [protocol, _command, transfer_id | _rest], code, message) do
    FileTransferLane.handle_worker_frame(route_auth, [
      protocol,
      "ERROR",
      transfer_id,
      code,
      message
    ])
  end

  defp respond_to_put(route_auth, stored, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"WRITE_OPEN", [path, _original_size]} ->
        Agent.update(stored, &%{&1 | begin: path, chunks: []})

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
            {state.begin, zstd_decode_chunks!(state.chunks)}
          end)

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "WRITE_COMMITTED",
          transfer_id,
          path,
          u64(byte_size(content)),
          "8db84f6b892cfa6bdad930c907ecb808"
        ])
    end
  end

  defp respond_to_get(route_auth, stored, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
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

  defp register_ready_worker!(route), do: register_worker!(route, "ready")

  defp register_worker!(route, status) do
    now = DateTime.utc_now(:microsecond)
    worker_id = "worker-#{System.unique_integer([:positive])}"

    worker =
      Repo.insert!(%AgentComputerWorker{
        worker_id: worker_id,
        status: status,
        version: "test",
        capacity: %{},
        load: %{},
        transport_route: route,
        last_worker_heartbeat_at: now,
        started_at: now,
        metadata: %{"runtime" => "test"}
      })

    %{worker_id: worker.worker_id, row: worker}
  end

  defp build_upload!(content) do
    path = Path.join(System.tmp_dir!(), "ankole-upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)

    %Plug.Upload{
      filename: Path.basename(path),
      path: path,
      content_type: "application/octet-stream"
    }
  end

  defp u64(value), do: <<value::unsigned-big-integer-size(64)>>
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
    Enum.reduce(chunks, [], fn chunk, acc ->
      decoded = Ankole.Kernel.zstd_decompress_block(chunk, 2 * 1024 * 1024)
      true = is_binary(decoded)
      [decoded | acc]
    end)
    |> IO.iodata_to_binary()
  end

  defp multipart(conn, path, fields) do
    boundary = "ankole-test-boundary"

    body =
      Enum.map(fields, fn
        {:file, %Plug.Upload{path: file_path, filename: filename}} ->
          [
            "--#{boundary}\r\n",
            "content-disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
            "content-type: application/octet-stream\r\n\r\n",
            File.read!(file_path),
            "\r\n"
          ]

        {name, value} ->
          [
            "--#{boundary}\r\n",
            "content-disposition: form-data; name=\"#{name}\"\r\n\r\n",
            to_string(value),
            "\r\n"
          ]
      end) ++
        ["--#{boundary}--\r\n"]

    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> post(path, IO.iodata_to_binary(body))
  end

  defp bearer_conn(conn) do
    conn
    |> active_admin_conn()
    |> post(~p"/.internal-apis/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("worker-file-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
