defmodule Ankole.AgentWorkers.CloudflareTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.AgentWorkers.Cloudflare
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob
  alias Ankole.AgentWorkers.Providers.Configuration
  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerBootstrap
  alias Ankole.SessionsCase

  # These HTTP shapes are owned by tools/deploy/cloudflare/agent-workers/src/http.ts.
  # The SDK directory record is from @cloudflare/sandbox 1.0.0, src/directory-backup.ts.
  @backup %{
    "id" => "previous",
    "dir" => "/workspace",
    "format" => "tar+zstd/1",
    "size" => 123,
    "sha256" => "digest"
  }

  setup do
    previous = Application.get_env(:ankole, :cloudflare_adapter_req_options)
    Application.put_env(:ankole, :cloudflare_adapter_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, :cloudflare_adapter_req_options, previous),
        else: Application.delete_env(:ankole, :cloudflare_adapter_req_options)
    end)

    row =
      worker_provider_fixture(%{
        kind: "cloudflare",
        config: Cloudflare.definition().example,
        credentials: %{"adapterToken" => "tok"}
      })

    {:ok, provider} = Providers.load(row)
    %{provider: provider}
  end

  test "checks the adapter and the deployed target image", %{provider: provider} do
    stub(fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/health"}
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok"]
      Req.Test.json(conn, %{"version" => 2, "images" => [provider.runtime.image]})
    end)

    assert :ok = Cloudflare.check(provider)
    assert :ok = Cloudflare.prepare_image(provider, provider.runtime.image)

    assert {:error, {:cloudflare_image_not_deployed, "other"}} =
             Cloudflare.prepare_image(provider, "other")
  end

  test "creates the same generation with its committed storage pointer and provider identity", %{
    provider: provider
  } do
    provider = put_in(provider.settings["env"], %{"ANKOLE_LOG_LEVEL" => "info"})
    spec = WorkerBootstrap.agent_worker_spec(provider, "agent-1", "gen1", "secret-token", @backup)

    stub(fn conn ->
      assert {conn.method, conn.request_path} == {"PUT", "/agents/agent-1/worker"}
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Ankole.JSON.decode!(body) == %{
               "provider_id" => provider.provider_id,
               "generation" => "gen1",
               "image" => spec.image,
               "instance" => "standard-3",
               "storage_ref" => @backup,
               "env" => %{
                 "WORKER_ID" => "agent-1",
                 "ANKOLE_RUNTIME_FABRIC_ENDPOINT" =>
                   "wss://ankole.example.com/runtime-fabric/worker",
                 "ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY" => "secret-token",
                 "ANKOLE_WORKER_STORAGE" => "adapter",
                 "ANKOLE_WORKER_ADAPTER_URL" =>
                   "https://ankole-agent-workers.example.workers.dev",
                 "ANKOLE_LOG_LEVEL" => "info"
               }
             }

      conn |> Plug.Conn.put_status(201) |> Req.Test.json(worker("agent-1", "running"))
    end)

    assert {:ok, nil} = Cloudflare.create_instance(provider, spec)
    assert {:ok, nil} = Cloudflare.create_instance(provider, spec)
  end

  test "deletes one generation without deleting Agent storage or pretending to pause", %{
    provider: provider
  } do
    object = %{agent_uid: "agent-1", generation: "gen1", instance_ref: nil}

    for mode <- [:graceful, :now] do
      stub(fn conn ->
        assert {conn.method, conn.request_path} == {"DELETE", "/agents/agent-1/worker"}
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Ankole.JSON.decode!(body) == %{
                 "provider_id" => provider.provider_id,
                 "generation" => "gen1",
                 "mode" => Atom.to_string(mode),
                 "grace_seconds" => 300
               }

        conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{"accepted" => true})
      end)

      assert :ok = Cloudflare.delete_instance(provider, object, mode)
    end

    assert {:error, :pause_not_supported} = Cloudflare.pause_instance(provider, object)
    assert {:error, :pause_not_supported} = Cloudflare.resume_instance(provider, object)
  end

  test "lists only the requested provider including terminating instances", %{provider: provider} do
    stub(fn conn ->
      assert conn.query_params["provider_id"] == provider.provider_id

      case conn.request_path do
        "/agents/agent-1/worker" ->
          Req.Test.json(conn, worker("agent-1", "running"))

        "/agents/agent-2/worker" ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "worker_not_found"})

        "/workers" ->
          Req.Test.json(conn, %{"workers" => [worker("agent-1", "terminating")]})
      end
    end)

    assert {:ok, [%{agent_uid: "agent-1", generation: "gen1", phase: :running, reason: nil}]} =
             Cloudflare.list_instances(provider, "agent-1")

    assert {:ok, []} = Cloudflare.list_instances(provider, "agent-2")
    assert {:ok, [%{phase: :terminating}]} = Cloudflare.list_instances(provider, :all)
  end

  test "only definite refusal rejects a generation; conflicts and transport errors remain uncertain",
       %{provider: provider} do
    spec = WorkerBootstrap.agent_worker_spec(provider, "agent-1", "gen2", "token")

    for status <- [400, 401, 403, 422, 409, 500, 503] do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(status)
        |> Req.Test.json(%{"error" => "platform_error", "message" => "detail"})
      end)

      result = Cloudflare.create_instance(provider, spec)

      if status in [400, 401, 403, 422],
        do:
          assert({:rejected, {:cloudflare_adapter, ^status, "platform_error", "detail"}} = result),
        else:
          assert({:error, {:cloudflare_adapter, ^status, "platform_error", "detail"}} = result)
    end

    stub(&Req.Test.transport_error(&1, :econnrefused))

    assert {:error, {:cloudflare_adapter_unreachable, %Req.TransportError{reason: :econnrefused}}} =
             Cloudflare.create_instance(provider, spec)
  end

  test "an absent transaction commits the backup pointer and the error after the container disappears",
       %{provider: provider} do
    uid = observed_worker(provider)

    stub(fn conn ->
      assert conn.query_params["provider_id"] == provider.provider_id

      case conn.request_path do
        "/agents/" <> rest ->
          if String.ends_with?(rest, "/worker"),
            do:
              conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "worker_not_found"}),
            else:
              Req.Test.json(conn, %{
                "storage_ref" => @backup,
                "reason" => "backup failed: R2 unavailable"
              })
      end
    end)

    assert :ok = perform_job(ReconcileJob, %{agent_uid: uid})

    assert %AgentWorker{
             state: "absent",
             generation: nil,
             token_ciphertext: nil,
             storage_ref: @backup,
             last_error: "backup failed: R2 unavailable"
           } = Repo.get!(AgentWorker, uid)
  end

  test "a failed storage observation cannot end the generation", %{provider: provider} do
    uid = observed_worker(provider)
    generation = Repo.get!(AgentWorker, uid).generation

    stub(fn conn ->
      if String.ends_with?(conn.request_path, "/worker"),
        do: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "worker_not_found"}),
        else: conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"error" => "unavailable"})
    end)

    assert {:error, {:cloudflare_adapter, 503, "unavailable", nil}} =
             perform_job(ReconcileJob, %{agent_uid: uid})

    assert %AgentWorker{state: "draining", generation: ^generation, last_error: reason} =
             Repo.get!(AgentWorker, uid)

    assert reason =~ "unavailable"
  end

  test "schema validates instance size and reserved fields; lifecycle settings keep the instance digest" do
    definition = Cloudflare.definition()
    {:ok, base} = Configuration.parse(definition.schema, definition.example)
    # start() accepts fractional vCPU, but memoryMib and diskMb are integers.
    # https://developers.cloudflare.com/containers/api/durable-object-container/#start
    custom = %{"cpus" => 1.5, "memoryMiB" => 8192, "diskMB" => 16_000}

    assert {:ok, %{"instance" => ^custom}} =
             Configuration.parse(
               definition.schema,
               Ankole.JSON.encode!(Map.put(base, "instance", custom))
             )

    for {key, value, path} <- [
          {"instance", "standard-unknown", "instance"},
          {"instance", Map.put(custom, "memoryMiB", 8192.5), "instance"},
          {"instance", Map.put(custom, "diskMB", 16_000.5), "instance"},
          {"instance", Map.delete(custom, "diskMB"), "instance"},
          {"image", "other", "image"},
          {"env", %{"WORKER_ID" => "other"}, "env.WORKER_ID"},
          {"env", %{"N" => 1}, "env.N"}
        ] do
      assert {:error, {:invalid_worker_provider_config, errors}} =
               Configuration.parse(
                 definition.schema,
                 Ankole.JSON.encode!(Map.put(base, key, value))
               )

      assert Enum.any?(errors, &String.starts_with?(&1.path, path))
    end

    assert Configuration.digest(definition.schema, base) ==
             Configuration.digest(definition.schema, Map.put(base, "stopGraceSeconds", 30))

    refute Configuration.digest(definition.schema, base) ==
             Configuration.digest(definition.schema, Map.put(base, "instance", "standard-4"))
  end

  defp observed_worker(provider) do
    %{principal: agent} = agent_fixture(%{worker_provider_id: provider.provider_id})
    :ok = SessionsCase.provision_worker(agent.uid)

    Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^agent.uid),
      set: [
        state: "draining",
        drain_reason: "idle_release",
        wanted_until: nil,
        initial_start_pending: false,
        instance_seen_at: DateTime.utc_now(:microsecond)
      ]
    )

    agent.uid
  end

  defp stub(fun), do: Req.Test.stub(__MODULE__, &fun.(Plug.Conn.fetch_query_params(&1)))

  defp worker(uid, phase),
    do: %{
      "agent_uid" => uid,
      "generation" => "gen1",
      "phase" => phase,
      "reason" => nil,
      "started_at" => "2026-10-07T00:00:00Z"
    }
end
