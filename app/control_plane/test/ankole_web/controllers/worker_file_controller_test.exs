defmodule AnkoleWeb.WorkerFileControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.WorkerFilesFake

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    {:ok, route: "worker-file-test-#{System.unique_integer([:positive])}"}
  end

  test "list returns entries and truncation from the worker", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)

    WorkerFilesFake.start!(route,
      files: %{"/agent_sessions/agent-1/sessions/session-1/log.txt" => "logs"}
    )

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=agent_sessions&path=agent-1/sessions"
      )

    assert %{
             "file_listing" => %{
               "root" => "agent_sessions",
               "path" => "agent-1/sessions",
               "truncated" => false,
               "entries" => [entry]
             }
           } = json_response(conn, 200)

    assert entry["relative_path"] == "agent-1/sessions/session-1/log.txt"
    assert entry["kind"] == "file"
    assert entry["size"] == 4
  end

  test "upload relays the multipart file and returns size and relative path", %{
    conn: conn,
    route: route
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)
    fake = WorkerFilesFake.start!(route)
    upload = build_upload!("hello world")

    conn =
      bearer_conn(conn)
      |> multipart(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files",
        root: "agent_sessions",
        path: "agent-1/sessions/session-1/inbox/note.txt",
        file: upload
      )

    assert %{
             "uploaded_file" => %{
               "root" => "agent_sessions",
               "relative_path" => "agent-1/sessions/session-1/inbox/note.txt",
               "size" => 11
             }
           } = json_response(conn, 200)

    assert %{"/agent_sessions/agent-1/sessions/session-1/inbox/note.txt" => "hello world"} =
             WorkerFilesFake.files(fake)
  end

  test "upload rejects a file over the transfer bound before any relay", %{
    conn: conn,
    route: route
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)
    fake = WorkerFilesFake.start!(route)
    upload = build_upload!(:binary.copy(<<0>>, Ankole.WorkerFiles.max_transfer_bytes() + 1))

    conn =
      bearer_conn(conn)
      |> multipart(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files",
        root: "user_files",
        path: "agent-1/user-files/huge.bin",
        file: upload
      )

    assert %{"error" => %{"code" => "file_too_large"}} = json_response(conn, 422)
    assert WorkerFilesFake.writes(fake) == []
  end

  test "download streams file content with content-disposition", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)
    content = :crypto.strong_rand_bytes(3 * 1024 * 1024)

    WorkerFilesFake.start!(route,
      files: %{"/user_files/agent-1/user-files/attachments/hello world.txt" => content}
    )

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files/content?root=user_files&path=agent-1/user-files/attachments/hello world.txt"
      )

    assert response(conn, 200) == content

    assert Plug.Conn.get_resp_header(conn, "content-disposition") |> List.first() =~
             "hello%20world.txt"

    assert Plug.Conn.get_resp_header(conn, "content-type") |> List.first() =~
             "application/octet-stream"
  end

  test "download maps a worker read error to 404", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)

    WorkerFilesFake.start!(route,
      fail: %{"push" => {"not_regular_file", "not a regular file: /agents/agent-1/sessions"}}
    )

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files/content?root=agent_sessions&path=agent-1/sessions"
      )

    assert %{
             "error" => %{
               "code" => "worker_file_error",
               "details" => [%{"code" => "not_regular_file"}]
             }
           } =
             json_response(conn, 404)
  end

  test "download surfaces file_too_large from the worker's size check", %{
    conn: conn,
    route: route
  } do
    %{worker_id: worker_id} = register_ready_worker!(route)

    WorkerFilesFake.start!(route,
      on_read: fn _path ->
        {:ok, :binary.copy(<<0>>, Ankole.WorkerFiles.max_transfer_bytes() + 1)}
      end
    )

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files/content?root=user_files&path=agent-1/user-files/big.bin"
      )

    assert %{"error" => %{"details" => [%{"code" => "file_too_large"}]}} =
             json_response(conn, 404)
  end

  test "download fails closed when the relay token is wrong", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)

    WorkerFilesFake.start!(route,
      files: %{"/user_files/agent-1/user-files/a.txt" => "secret"},
      tamper_token: true
    )

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files/content?root=user_files&path=agent-1/user-files/a.txt"
      )

    assert %{"error" => %{"details" => [%{"code" => "relay_failed"}]}} = json_response(conn, 404)
  end

  test "move renames a path", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)

    fake =
      WorkerFilesFake.start!(route,
        files: %{"/user_files/agent-1/user-files/inbox/message-1/hello.txt" => "hi"}
      )

    conn =
      bearer_conn(conn)
      |> post(~p"/api/v1/agent-computer-workers/#{worker_id}/file-moves", %{
        "root" => "user_files",
        "from_path" => "agent-1/user-files/inbox/message-1/hello.txt",
        "to_path" => "agent-1/user-files/archive/message-1/hello.txt",
        "overwrite" => false
      })

    assert %{
             "moved_file" => %{
               "root" => "user_files",
               "from_relative_path" => "agent-1/user-files/inbox/message-1/hello.txt",
               "to_relative_path" => "agent-1/user-files/archive/message-1/hello.txt",
               "moved" => true
             }
           } = json_response(conn, 200)

    assert %{"/user_files/agent-1/user-files/archive/message-1/hello.txt" => "hi"} =
             WorkerFilesFake.files(fake)
  end

  test "delete removes a path", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)

    fake =
      WorkerFilesFake.start!(route,
        files: %{"/user_files/agent-1/user-files/archive/message-1/hello.txt" => "hi"}
      )

    conn =
      bearer_conn(conn)
      |> delete(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=user_files&path=agent-1/user-files/archive/message-1/hello.txt&recursive=true"
      )

    assert %{
             "deleted_file" => %{
               "root" => "user_files",
               "relative_path" => "agent-1/user-files/archive/message-1/hello.txt",
               "deleted" => true
             }
           } = json_response(conn, 200)

    assert WorkerFilesFake.files(fake) == %{}
  end

  test "unknown worker returns 404 worker_not_found", %{conn: conn} do
    conn =
      bearer_conn(conn)
      |> get(~p"/api/v1/agent-computer-workers/missing-worker/files?root=agent_sessions")

    assert %{"error" => %{"code" => "worker_not_found"}} = json_response(conn, 404)
  end

  test "stale worker returns 409 worker_not_ready", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_worker!(route, "stale")

    conn =
      bearer_conn(conn)
      |> get(~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=agent_sessions")

    assert %{"error" => %{"code" => "worker_not_ready"}} = json_response(conn, 409)
  end

  test "worker error in list maps to 404", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)
    WorkerFilesFake.start!(route, fail: %{"list" => {"file_not_found", "path does not exist"}})

    conn =
      bearer_conn(conn)
      |> get(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=agent_sessions&path=agent-1/sessions/missing"
      )

    assert %{"error" => %{"code" => "worker_file_error", "message" => "path does not exist"}} =
             json_response(conn, 404)
  end

  test "worker error in move maps to 422", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)
    WorkerFilesFake.start!(route)

    conn =
      bearer_conn(conn)
      |> post(~p"/api/v1/agent-computer-workers/#{worker_id}/file-moves", %{
        "root" => "user_files",
        "from_path" => "agent-1/user-files/a.txt",
        "to_path" => "agent-1/user-files/b.txt"
      })

    assert %{"error" => %{"code" => "worker_file_error"}} = json_response(conn, 422)
  end

  test "worker error in delete maps to 422", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)
    WorkerFilesFake.start!(route)

    conn =
      bearer_conn(conn)
      |> delete(
        ~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=user_files&path=agent-1/user-files/missing.txt"
      )

    assert %{
             "error" => %{
               "code" => "worker_file_error",
               "details" => [%{"code" => "file_not_found"}]
             }
           } = json_response(conn, 422)
  end

  test "invalid root is rejected by cast and validate", %{conn: conn, route: route} do
    %{worker_id: worker_id} = register_ready_worker!(route)

    conn =
      bearer_conn(conn)
      |> get(~p"/api/v1/agent-computer-workers/#{worker_id}/files?root=shared_files")

    assert conn.status == 422
  end

  describe "relay endpoint" do
    test "answers 404 for an unknown transfer and 401 without a token", %{conn: conn} do
      conn = get(conn, "/internal/runtime-fabric/file-relay/missing?token=abc")
      assert %{"error" => %{"code" => "unknown_transfer"}} = json_response(conn, 404)

      route = "relay-direct-#{System.unique_integer([:positive])}"
      worker = register_ready_worker!(route).row

      {:ok, %{transfer_id: transfer_id, url: url}} =
        Ankole.WorkerFiles.Relay.open(%{
          direction: :push,
          worker: worker,
          root: "user_files",
          relative_path: "inbox/a.txt",
          max_bytes: 4,
          ttl_ms: 60_000,
          consumer: self(),
          owner: self()
        })

      %URI{path: path, query: "token=" <> token} = URI.parse(url)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/octet-stream")
        |> put(path, "")

      assert %{"error" => %{"code" => "invalid_token"}} = json_response(conn, 401)

      conn = get(build_conn(), path <> "?token=" <> token)
      assert %{"error" => %{"code" => "method_mismatch"}} = json_response(conn, 405)

      conn =
        build_conn()
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", "10")
        |> put(path <> "?token=" <> token, "0123456789")

      assert %{"error" => %{"code" => "file_too_large"}} = json_response(conn, 413)
      refute_received {:relay_opened, ^transfer_id, _handler, _size}

      conn =
        build_conn()
        |> put_req_header("content-type", "application/octet-stream")
        |> put_req_header("content-length", "1")
        |> put(path <> "?token=" <> token, "x")

      assert %{"error" => %{"code" => "transfer_consumed"}} = json_response(conn, 409)
    end
  end

  defp register_ready_worker!(route), do: register_worker!(route, "ready")

  defp register_worker!(route, status) do
    now = DateTime.utc_now(:microsecond)
    worker_id = "worker-#{System.unique_integer([:positive])}"

    worker =
      Repo.insert!(%AgentComputerWorker{
        worker_id: worker_id,
        incarnation_id: Ecto.UUID.generate(),
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
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{
      filename: Path.basename(path),
      path: path,
      content_type: "application/octet-stream"
    }
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
end
