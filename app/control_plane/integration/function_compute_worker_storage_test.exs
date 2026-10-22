defmodule Ankole.FunctionComputeWorkerStorageIntegrationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.WorkerStorageFixtures
  alias Ankole.Principals
  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Providers
  alias Ankole.Plugins.ChinaMarketAIProviders.WorkerProviders.FunctionCompute

  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerBootstrap

  @moduletag cloud: true, sandbox: false, timeout: 3_600_000

  setup %{tenant: tenant} do
    secrets =
      System.fetch_env!("ANKOLE_FUNCTION_COMPUTE_TEST_CREDENTIALS_FILE")
      |> File.read!()
      |> Ankole.JSON.decode!()

    config = System.fetch_env!("ANKOLE_FUNCTION_COMPUTE_TEST_CONFIG_FILE") |> File.read!()
    {:ok, settings} = YamlElixir.read_from_string(config)
    origin = System.fetch_env!("ANKOLE_FUNCTION_COMPUTE_TEST_CP_ORIGIN")
    image = System.fetch_env!("ANKOLE_FUNCTION_COMPUTE_TEST_IMAGE")
    replacement = System.fetch_env!("ANKOLE_FUNCTION_COMPUTE_TEST_REPLACEMENT_IMAGE")
    port = System.fetch_env!("ANKOLE_FUNCTION_COMPUTE_TEST_CP_PORT") |> String.to_integer()
    refute image == replacement
    {:ok, previous} = Config.fetch()
    :ok = Config.put(previous |> Map.to_list() |> Keyword.put(:image, image))
    on_exit(fn -> Config.put(Map.to_list(previous)) end)
    Ankole.E2E.Harness.start_ai_gateway_test_http_server!(port)

    %{principal: owner} = human_fixture()

    config =
      settings
      |> Map.put("idleReleaseAfter", "never")
      |> Map.put("endpoints", %{
        "runtimeFabricUrl" =>
          String.replace_prefix(origin, "https://", "wss://") <> "/runtime-fabric/worker",
        "relayOrigin" => origin,
        "aiGatewayUrl" => origin <> "/api/v1/ai-gateway"
      })
      |> Ankole.JSON.encode!()

    {uids, ids} =
      storage_agents!(
        "function_compute",
        Ankole.Ecto.UUIDv7.autogenerate(),
        owner.uid,
        config,
        secrets
      )

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> cleanup_storage!(uids, ids, owner.uid) end)

      cleanup_tenant!(tenant)
    end)

    %{uids: uids, replacement: replacement, runtime: previous, owner: owner}
  end

  test "persistent Home survives pause, termination, and image replacement; deletion removes only its Agent",
       context do
    [uid, peer_uid] = context.uids
    first = await_worker_state!(uid, :ready)
    peer = await_worker_state!(peer_uid, :ready)
    {:ok, provider} = Providers.load(first.provider_id)
    {:ok, peer_provider} = Providers.load(peer.provider_id)
    put_proof!(first, "HOME-BEFORE-PAUSE")
    put_proof!(peer, "OTHER-PROVIDER")

    assert {:ok, [%{agent_uid: ^uid, instance_ref: ref}]} =
             FunctionCompute.list_instances(provider, :all)

    assert ref == first.instance_ref
    assert {:ok, [%{agent_uid: ^peer_uid}]} = FunctionCompute.list_instances(peer_provider, :all)

    assert {:ok, token} = AgentWorkers.credential(first)
    spec = WorkerBootstrap.agent_worker_spec(provider, uid, first.generation, token)
    assert {:ok, ^ref} = FunctionCompute.create_instance(provider, %{spec | instance_ref: ref})

    assert {:ok, _} = Principals.delete_agent(uid)
    paused = await_worker_state!(uid, :paused)
    assert paused.generation == first.generation
    assert {:ok, [%{phase: :paused}]} = FunctionCompute.list_instances(provider, uid)
    # A long pause can leave OSSFS2 with unusable TCP connections.
    # A short pause can retain working connections and miss this failure.
    if provider.settings["storage"]["oss"], do: Process.sleep(90_000)
    assert {:ok, _} = Principals.enable_agent(uid)
    assert :ok = AgentWorkers.request(uid)
    resumed = await_worker_state!(uid, :ready)
    assert resumed.instance_ref == first.instance_ref
    assert resumed.incarnation_id == first.incarnation_id
    read_started = System.monotonic_time(:millisecond)
    assert_proof!(resumed, "HOME-BEFORE-PAUSE")

    if provider.settings["storage"]["oss"],
      do: assert(System.monotonic_time(:millisecond) - read_started < 30_000)

    # Terminate through the real Function Compute adapter outside reconciliation. A new
    # generation must mount the same AgenticFS or OSS location after the platform confirms exit.
    put_proof!(resumed, "HOME-BEFORE-TERMINATION")

    assert :ok =
             FunctionCompute.delete_instance(
               provider,
               %{
                 agent_uid: uid,
                 generation: resumed.generation,
                 instance_ref: resumed.instance_ref
               },
               :now
             )

    recovered = await_worker_state!(uid, :ready, resumed.generation)
    refute recovered.instance_ref == resumed.instance_ref
    assert_proof!(recovered, "HOME-BEFORE-TERMINATION")

    put_proof!(recovered, "HOME-BEFORE-IMAGE-CHANGE")
    :ok = Config.put(context.runtime |> Map.to_list() |> Keyword.put(:image, context.replacement))
    changed = await_worker_state!(uid, :ready, recovered.generation)
    assert changed.image == context.replacement
    assert_proof!(changed, "HOME-BEFORE-IMAGE-CHANGE")
    assert {:ok, _} = Principals.delete_agent(uid)
    assert {:ok, _} = Principals.delete_agent(uid)
    assert await_worker_state!(uid, nil) == nil
    assert {:ok, []} = FunctionCompute.list_instances(provider, uid)
    assert_proof!(Repo.get!(AgentWorker, peer_uid), "OTHER-PROVIDER")

    assert {:ok, [%{generation: generation}]} =
             FunctionCompute.list_instances(peer_provider, :all)

    assert generation == peer.generation
  end
end
