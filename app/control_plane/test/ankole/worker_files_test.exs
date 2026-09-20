defmodule Ankole.WorkerFilesTest do
  use Ankole.DataCase, async: true

  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.WorkerFiles
  alias Ankole.WorkerFiles.Relay
  alias Ankole.WorkerFilesFake

  setup do
    {:ok, route: "worker-files-test-#{System.unique_integer([:positive])}"}
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

    path = Path.join(System.tmp_dir!(), "ankole-oversize-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:file_too_large, ^oversize, ^max_bytes}} =
             WorkerFiles.put("user_files", "inbox/huge.bin", {:file, path})
  end

  test "put relays binary and file sources through the signed URL", %{route: route} do
    insert_ready_worker!(route)
    fake = WorkerFilesFake.start!(route)

    assert {:ok, %{"relative_path" => "inbox/a.txt", "size" => 11, "xxh3_128" => fingerprint}} =
             WorkerFiles.put("user_files", "inbox/a.txt", "hello world")

    assert is_binary(fingerprint)

    path = Path.join(System.tmp_dir!(), "ankole-put-#{System.unique_integer([:positive])}")
    File.write!(path, "from a file")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{"relative_path" => "inbox/b.txt", "size" => 11}} =
             WorkerFiles.put("user_files", "inbox/b.txt", {:file, path})

    assert %{
             "/user_files/inbox/a.txt" => "hello world",
             "/user_files/inbox/b.txt" => "from a file"
           } = WorkerFilesFake.files(fake)

    assert {:ok, %{"content" => "hello world", "size" => 11}} =
             WorkerFiles.get("user_files", "inbox/a.txt")
  end

  test "stream delivers a multi-chunk file in order", %{route: route} do
    insert_ready_worker!(route)
    content = :crypto.strong_rand_bytes(3 * 1024 * 1024)
    WorkerFilesFake.start!(route, files: %{"/user_files/inbox/big.bin" => content})

    assert {:ok, %{"size" => size, "body" => body}} =
             WorkerFiles.stream("user_files", "inbox/big.bin")

    assert size == byte_size(content)
    chunks = Enum.to_list(body)
    assert length(chunks) > 1
    assert IO.iodata_to_binary(chunks) == content
    assert Registry.count(Ankole.WorkerFiles.RelayRegistry) == 0
  end

  test "push relay rejects a body over the byte bound before reading it", %{route: route} do
    insert_ready_worker!(route)
    max_bytes = WorkerFiles.max_transfer_bytes()

    WorkerFilesFake.start!(route,
      on_read: fn _path -> {:ok, :binary.copy(<<0>>, max_bytes + 1)} end
    )

    assert {:error, %{"code" => "file_too_large"}} =
             WorkerFiles.get("user_files", "inbox/huge.bin")
  end

  test "push relay refuses a tampered token", %{route: route} do
    insert_ready_worker!(route)
    content = "secret bytes"

    WorkerFilesFake.start!(route,
      files: %{"/user_files/inbox/a.txt" => content},
      tamper_token: true
    )

    assert {:error, %{"code" => "relay_failed", "message" => message}} =
             WorkerFiles.get("user_files", "inbox/a.txt")

    assert message =~ "401"
  end

  test "worker errors surface with their code", %{route: route} do
    insert_ready_worker!(route)
    WorkerFilesFake.start!(route)

    assert {:error, %{"code" => "file_not_found"}} =
             WorkerFiles.get("user_files", "inbox/missing.txt")

    assert {:error, %{"code" => "file_not_found"}} =
             WorkerFiles.delete("user_files", "inbox/missing.txt")
  end

  test "list, move, and delete are worker-owned RPCs", %{route: route} do
    insert_ready_worker!(route)

    WorkerFilesFake.start!(route,
      files: %{"/agent_sessions/agent-1/sessions/session-1/log.txt" => "logs"}
    )

    assert {:ok,
            %{
              "root" => "agent_sessions",
              "relative_path" => "agent-1/sessions",
              "truncated" => false,
              "entries" => [
                %{
                  "relative_path" => "agent-1/sessions/session-1/log.txt",
                  "kind" => "file",
                  "size" => 4
                }
              ]
            }} = WorkerFiles.list("agent_sessions", "agent-1/sessions")

    assert {:ok, %{"moved" => true, "to_relative_path" => "agent-1/sessions/archive/log.txt"}} =
             WorkerFiles.move(
               "agent_sessions",
               "agent-1/sessions/session-1/log.txt",
               "agent-1/sessions/archive/log.txt"
             )

    assert {:ok, %{"deleted" => true}} =
             WorkerFiles.delete("agent_sessions", "agent-1/sessions/archive/log.txt")

    assert {:ok, %{"entries" => []}} = WorkerFiles.list("agent_sessions", "agent-1/sessions")
  end

  test "worker_id pins the route to that worker", %{route: route} do
    %{worker_id: worker_id} = insert_ready_worker!(route)
    WorkerFilesFake.start!(route)

    assert {:ok, %{"root" => "agent_sessions"}} =
             WorkerFiles.list("agent_sessions", "agent-1/sessions", worker_id: worker_id)

    assert {:error, :worker_not_found} =
             WorkerFiles.list("agent_sessions", "agent-1/sessions", worker_id: "missing-worker")
  end

  test "Codex state is not exposed as a worker file root" do
    refute "codex_accounts" in WorkerFiles.roots()

    assert {:error, {:unsupported_file_root, "codex_accounts"}} =
             WorkerFiles.get("codex_accounts", "account-1/auth.json")

    assert {:error, {:unsupported_file_root, "codex_accounts"}} =
             WorkerFiles.delete("codex_accounts", "account-1", recursive: true)
  end

  test "shared-route operations fail without a ready worker" do
    assert {:error, :no_worker_available} = WorkerFiles.get("user_files", "inbox/a.txt")
  end

  test "sanitize_path_segment bounds provider names to one safe segment" do
    assert WorkerFiles.sanitize_path_segment("report (final).xlsx") == "report_final_.xlsx"

    assert WorkerFiles.sanitize_path_segment(String.duplicate("a", 200)) ==
             String.duplicate("a", 160)

    sanitized = WorkerFiles.sanitize_path_segment("Q3 报表 (final).xlsx")
    assert sanitized =~ ~r/^[A-Za-z0-9._-]+$/
    assert String.length(sanitized) <= 160

    for degenerate <- ["", ".", "..", "///", nil, 42] do
      assert WorkerFiles.sanitize_path_segment(degenerate) == "attachment"
    end
  end

  describe "relay sessions" do
    test "are one-time, method-bound, and expire", %{route: route} do
      worker = insert_ready_worker!(route)

      {:ok, %{transfer_id: transfer_id, url: url}} =
        Relay.open(%{
          direction: :pull,
          worker: worker,
          root: "user_files",
          relative_path: "inbox/a.txt",
          max_bytes: 10,
          ttl_ms: 60_000,
          source: {:binary, "hello"},
          owner: self()
        })

      %URI{query: "token=" <> token} = URI.parse(url)

      assert {:error, :invalid_token} = Relay.consume(transfer_id, "GET", token <> "x")
      assert {:error, :invalid_token} = Relay.consume(transfer_id, "GET", nil)
      assert {:error, :method_mismatch} = Relay.consume(transfer_id, "PUT", token)
      assert {:ok, %{source: {:binary, "hello"}}} = Relay.consume(transfer_id, "GET", token)
      assert {:error, :consumed} = Relay.consume(transfer_id, "GET", token)
      assert {:error, :not_found} = Relay.consume("missing", "GET", token)

      {:ok, %{transfer_id: expired_id, url: expired_url}} =
        Relay.open(%{
          direction: :push,
          worker: worker,
          root: "user_files",
          relative_path: "inbox/b.txt",
          max_bytes: 10,
          ttl_ms: 0,
          consumer: self(),
          owner: self()
        })

      %URI{query: "token=" <> expired_token} = URI.parse(expired_url)
      Process.sleep(20)
      assert {:error, reason} = Relay.consume(expired_id, "PUT", expired_token)
      assert reason in [:expired, :not_found]
    end

    test "stop when the owner exits", %{route: route} do
      worker = insert_ready_worker!(route)
      parent = self()

      owner =
        spawn(fn ->
          {:ok, session} =
            Relay.open(%{
              direction: :pull,
              worker: worker,
              root: "user_files",
              relative_path: "inbox/a.txt",
              max_bytes: 10,
              ttl_ms: 60_000,
              source: {:binary, "hello"},
              owner: self()
            })

          send(parent, {:opened, session.transfer_id})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:opened, transfer_id}
      assert [{_pid, _value}] = Registry.lookup(Ankole.WorkerFiles.RelayRegistry, transfer_id)
      send(owner, :stop)
      Process.sleep(20)
      assert [] = Registry.lookup(Ankole.WorkerFiles.RelayRegistry, transfer_id)
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
end
