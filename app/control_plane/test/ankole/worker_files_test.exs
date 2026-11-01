defmodule Ankole.WorkerFilesTest do
  use Ankole.DataCase, async: false

  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers
  alias Ankole.WorkerFiles
  alias Ankole.WorkerFiles.Relay
  alias Ankole.WorkerFilesFake

  setup do
    {:ok, route: "worker-files-test-#{System.unique_integer([:positive])}"}
  end

  test "put rejects oversize content before any transfer starts" do
    max_bytes = WorkerFiles.max_transfer_bytes()
    oversize = max_bytes + 1
    path = temp_file!(:binary.copy(<<0>>, oversize))

    assert {:error, {:file_too_large, ^oversize, ^max_bytes}} =
             WorkerFiles.put("huge.bin", {:file, path})
  end

  test "put relays a local file to a path in the Worker's Agent Home", %{route: route} do
    worker = ready_worker(route)
    fake = WorkerFilesFake.start!(route)

    assert {:ok, %{"size" => 11}} =
             WorkerFiles.put("drive/a.txt", {:file, temp_file!("hello world")},
               worker: AgentWorkers.target(worker)
             )

    assert %{"drive/a.txt" => "hello world"} = WorkerFilesFake.files(fake)
  end

  test "stream delivers a multi-chunk file in order and then ends its relay session", %{
    route: route
  } do
    worker = ready_worker(route)
    content = :crypto.strong_rand_bytes(3 * 1024 * 1024)
    WorkerFilesFake.start!(route, files: %{"big.bin" => content})
    earlier_sessions = relay_sessions()

    assert {:ok, %{"size" => size, "body" => body}} =
             WorkerFiles.stream("big.bin", worker: AgentWorkers.target(worker))

    # Sessions of earlier tests can still stop in the background. This module
    # is not async, so the one new session belongs to this transfer.
    assert [{_transfer_id, session}] = relay_sessions() -- earlier_sessions
    assert Process.alive?(session)
    monitor = Process.monitor(session)

    assert size == byte_size(content)
    chunks = Enum.to_list(body)
    assert length(chunks) > 1
    assert IO.iodata_to_binary(chunks) == content
    assert_receive {:DOWN, ^monitor, :process, ^session, _reason}, 1_000
  end

  test "stream_prefix transfers a bounded prefix without rejecting a larger source", %{
    route: route
  } do
    worker = ready_worker(route)
    content = String.duplicate("large workspace text\n", 2_000)
    WorkerFilesFake.start!(route, files: %{"large.txt" => content})

    assert {:ok, %{"size" => 16_384, "body" => body}} =
             WorkerFiles.stream_prefix("large.txt", 16_384, worker: worker)

    assert body |> Enum.to_list() |> IO.iodata_to_binary() == binary_part(content, 0, 16_384)

    assert {:error, %{"code" => "file_too_large"}} =
             WorkerFiles.stream("large.txt", worker: worker, max_bytes: 16_384)
  end

  test "push relay rejects a body over the byte bound before reading it", %{route: route} do
    worker = ready_worker(route)
    max_bytes = WorkerFiles.max_transfer_bytes()

    WorkerFilesFake.start!(route,
      on_read: fn _path -> {:ok, :binary.copy(<<0>>, max_bytes + 1)} end
    )

    assert {:error, %{"code" => "file_too_large"}} =
             WorkerFiles.stream("huge.bin", worker: AgentWorkers.target(worker))
  end

  test "push relay refuses a tampered token", %{route: route} do
    worker = ready_worker(route)

    WorkerFilesFake.start!(route,
      files: %{"a.txt" => "secret bytes"},
      tamper_token: true
    )

    assert {:error, %{"code" => "relay_failed", "message" => message}} =
             WorkerFiles.stream("a.txt", worker: AgentWorkers.target(worker))

    assert message =~ "401"
  end

  test "worker errors surface with their code", %{route: route} do
    worker = ready_worker(route)
    WorkerFilesFake.start!(route)

    assert {:error, %{"code" => "file_not_found"}} =
             WorkerFiles.stream("missing.txt", worker: AgentWorkers.target(worker))
  end

  test "received-file callbacks keep the caller and tenant and always remove the local file", %{
    route: route
  } do
    worker = ready_worker(route)
    WorkerFilesFake.start!(route, files: %{"a.txt" => "complete bytes"})
    caller = self()
    tenant_id = Repo.tenant_id!()
    opts = [worker: AgentWorkers.target(worker)]

    assert {:ok, path} =
             WorkerFiles.with_received_file("a.txt", opts, fn path ->
               assert self() == caller
               assert Repo.tenant_id!() == tenant_id
               assert File.read!(path) == "complete bytes"
               {:ok, path}
             end)

    refute File.exists?(path)

    assert_raise RuntimeError, "callback failed", fn ->
      WorkerFiles.with_received_file("a.txt", opts, fn path ->
        send(caller, {:failed_callback_path, path})
        raise "callback failed"
      end)
    end

    assert_receive {:failed_callback_path, path}
    refute File.exists?(path)
  end

  test "received-file callbacks do not commit bytes before the final Worker acknowledgement", %{
    route: route
  } do
    worker = ready_worker(route)

    WorkerFilesFake.start!(route,
      files: %{"a.txt" => "bytes arrived"},
      push_result: {"read_failed", "Worker could not complete the source read"}
    )

    caller = self()

    assert {:error, %{"code" => "read_failed"}} =
             WorkerFiles.with_received_file(
               "a.txt",
               [worker: AgentWorkers.target(worker)],
               fn path -> send(caller, {:unexpected_commit, path}) end
             )

    refute_receive {:unexpected_commit, _path}
  end

  test "receive_bundle writes each file of one transfer to its own local file", %{
    route: route
  } do
    worker = ready_worker(route)
    large = :crypto.strong_rand_bytes(3 * 1024 * 1024)

    fake =
      WorkerFilesFake.start!(route,
        files: %{
          "jobs/7/a.txt" => "alpha",
          "jobs/7/sub/large.bin" => large,
          "jobs/7/empty.txt" => ""
        }
      )

    target_dir =
      Path.join(System.tmp_dir!(), "ankole-bundle-#{System.unique_integer([:positive])}")

    File.mkdir_p!(target_dir)
    on_exit(fn -> File.rm_rf(target_dir) end)

    assert {:ok, [alpha, large_path, empty]} =
             WorkerFiles.receive_bundle(
               "jobs",
               ["7/a.txt", "7/sub/large.bin", "7/empty.txt"],
               target_dir,
               worker: AgentWorkers.target(worker)
             )

    assert {File.read!(alpha), File.read!(large_path), File.read!(empty)} == {"alpha", large, ""}

    assert WorkerFilesFake.pushes(fake) == [
             %{
               home_relative_path: "jobs",
               bundle_paths: ["7/a.txt", "7/sub/large.bin", "7/empty.txt"]
             }
           ]
  end

  test "receive_bundle rejects a bundle that does not match the request", %{route: route} do
    entry = fn path, content ->
      [<<byte_size(path)::32-big>>, path, <<byte_size(content)::64-big>>, content]
    end

    for {body, reason} <- [
          {entry.("other.txt", "x"), :unexpected_path},
          {[entry.("a.txt", "x"), entry.("b.txt", "y")], :unexpected_path},
          {[<<5::32-big>>, "a.txt", <<10::64-big>>, "short"], :truncated},
          {[<<0::32-big>>], :path_length}
        ] do
      route = "#{route}-#{System.unique_integer([:positive])}"
      worker = ready_worker(route)

      WorkerFilesFake.start!(route,
        on_bundle: fn _request -> {:ok, IO.iodata_to_binary(body)} end
      )

      target_dir =
        Path.join(System.tmp_dir!(), "ankole-bundle-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_dir)
      on_exit(fn -> File.rm_rf(target_dir) end)

      assert {:error, {:invalid_bundle, ^reason}} =
               WorkerFiles.receive_bundle("jobs", ["a.txt"], target_dir,
                 worker: AgentWorkers.target(worker)
               )
    end
  end

  describe "relay sessions" do
    test "use saved generation endpoints even when current provider settings are invalid", %{
      route: route
    } do
      worker = ready_worker(route)
      alias Ankole.AgentWorkers.Providers
      alias Ankole.AgentWorkers.Providers.Provider
      config = "network: bridge\nendpoints:\n  relayOrigin: https://worker-files.example.test/\n"
      assert {:ok, provider} = Providers.update(worker.provider_id, %{config: config})
      Ankole.AgentWorkerDockerHTTP.install()
      assert :ok = Ankole.AgentWorkers.request(worker.agent_uid)

      assert :ok =
               perform_job(Ankole.AgentWorkers.ReconcileJob, %{
                 "agent_uid" => worker.agent_uid
               })

      attrs = %{
        direction: :push,
        worker: AgentWorkers.target(worker),
        max_bytes: 10,
        ttl_ms: 60_000,
        consumer: self()
      }

      assert {:ok, session} = Relay.open(attrs)

      assert String.starts_with?(
               session.url,
               "https://worker-files.example.test/internal/runtime-fabric/file-relay/"
             )

      Relay.close(session.transfer_id)

      assert {:ok, _} =
               Providers.update(worker.provider_id, %{
                 config:
                   "network: bridge\nendpoints:\n  relayOrigin: https://next.example.test/\n"
               })

      assert {:ok, session} = Relay.open(attrs)

      assert String.starts_with?(
               session.url,
               "https://worker-files.example.test/internal/runtime-fabric/file-relay/"
             )

      Relay.close(session.transfer_id)

      Repo.update_all(from(p in Provider, where: p.id == ^provider.id),
        set: [config: "unknown: true\n"]
      )

      assert {:ok, session} = Relay.open(attrs)
      assert String.starts_with?(session.url, "https://worker-files.example.test/")
      Relay.close(session.transfer_id)
    end

    test "are one-time, method-bound, and expire", %{route: route} do
      worker = ready_worker(route)

      {:ok, %{transfer_id: transfer_id, url: url}} =
        Relay.open(%{
          direction: :pull,
          worker: AgentWorkers.target(worker),
          max_bytes: 10,
          ttl_ms: 60_000,
          source: {:file, "/tmp/a.txt"},
          owner: self()
        })

      %URI{query: "token=" <> token} = URI.parse(url)

      assert {:error, :invalid_token} = Relay.consume(transfer_id, "GET", token <> "x")
      assert {:error, :invalid_token} = Relay.consume(transfer_id, "GET", nil)
      assert {:error, :method_mismatch} = Relay.consume(transfer_id, "PUT", token)
      assert {:ok, %{source: {:file, "/tmp/a.txt"}}} = Relay.consume(transfer_id, "GET", token)
      assert {:error, :consumed} = Relay.consume(transfer_id, "GET", token)
      assert {:error, :not_found} = Relay.consume("missing", "GET", token)

      {:ok, %{transfer_id: expired_id, url: expired_url}} =
        Relay.open(%{
          direction: :push,
          worker: AgentWorkers.target(worker),
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
      worker = ready_worker(route)
      parent = self()

      owner =
        spawn(
          Repo.bind_tenant(fn ->
            receive do
              :start -> :ok
            end

            {:ok, session} =
              Relay.open(%{
                direction: :pull,
                worker: AgentWorkers.target(worker),
                max_bytes: 10,
                ttl_ms: 60_000,
                source: {:file, "/tmp/a.txt"},
                owner: self()
              })

            send(parent, {:opened, session.transfer_id})

            receive do
              :stop -> :ok
            end
          end)
        )

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), owner)
      send(owner, :start)

      assert_receive {:opened, transfer_id}
      assert [{_pid, _value}] = Registry.lookup(Ankole.WorkerFiles.RelayRegistry, transfer_id)
      send(owner, :stop)
      Process.sleep(20)
      assert [] = Registry.lookup(Ankole.WorkerFiles.RelayRegistry, transfer_id)
    end
  end

  defp relay_sessions do
    Registry.select(Ankole.WorkerFiles.RelayRegistry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end

  defp ready_worker(route) do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    %{Repo.get_by!(AgentWorker, agent_uid: agent.uid) | state: :ready, transport_route: route}
  end

  defp temp_file!(content) do
    path = Path.join(System.tmp_dir!(), "ankole-put-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
