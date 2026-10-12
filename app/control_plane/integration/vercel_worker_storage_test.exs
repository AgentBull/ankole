defmodule Ankole.VercelWorkerStorageIntegrationTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.WorkerStorageFixtures
  alias Ankole.Principals
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{Config, ProviderKind, Providers, Vercel}

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Vercel.Client
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap

  @moduletag cloud: true, sandbox: false, timeout: 1_800_000

  setup %{tenant: tenant} do
    token = System.fetch_env!("ANKOLE_VERCEL_TEST_TOKEN_FILE") |> File.read!() |> String.trim()
    origin = System.fetch_env!("ANKOLE_VERCEL_TEST_CP_ORIGIN")
    image = System.fetch_env!("ANKOLE_VERCEL_TEST_IMAGE")
    replacement = System.fetch_env!("ANKOLE_VERCEL_TEST_REPLACEMENT_IMAGE")
    port = System.fetch_env!("ANKOLE_VERCEL_TEST_CP_PORT") |> String.to_integer()
    refute image == replacement
    {:ok, previous} = Config.fetch()
    :ok = Config.put(previous |> Map.to_list() |> Keyword.put(:image, image))
    on_exit(fn -> Config.put(Map.to_list(previous)) end)
    Ankole.E2E.Harness.start_ai_gateway_test_http_server!(port)

    %{principal: owner} = human_fixture()

    config =
      Ankole.JSON.encode!(%{
        teamId: System.fetch_env!("ANKOLE_VERCEL_TEST_TEAM_ID"),
        projectId: System.fetch_env!("ANKOLE_VERCEL_TEST_PROJECT_ID"),
        region: System.fetch_env!("ANKOLE_VERCEL_TEST_REGION"),
        imageRepository: System.fetch_env!("ANKOLE_VERCEL_TEST_IMAGE_REPOSITORY"),
        driveSizeGiB: 2,
        cpus: 2,
        idleReleaseAfter: "never",
        endpoints: %{
          runtimeFabricUrl:
            String.replace_prefix(origin, "https://", "wss://") <> "/runtime-fabric/worker",
          relayOrigin: origin,
          aiGatewayUrl: origin <> "/api/v1/ai-gateway"
        }
      })

    {uids, ids} =
      storage_agents!("vercel", Ankole.Ecto.UUIDv7.autogenerate(), owner.uid, config, %{
        "token" => token
      })

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> cleanup_storage!(uids, ids, owner.uid) end)

      Repo.delete!(tenant)
    end)

    %{uids: uids, replacement: replacement, runtime: previous}
  end

  test "real Drives survive deletion, a stopped VM, and image replacement; Agent deletion removes only its Drive",
       context do
    [uid, peer_uid] = context.uids
    first = await_worker_state!(uid, "ready")
    peer = await_worker_state!(peer_uid, "ready")
    {:ok, provider} = Providers.load(first.provider_id)
    {:ok, peer_provider} = Providers.load(peer.provider_id)
    assert_worker_user!(provider, first)
    put_proof!(first, "HOME-BEFORE-DELETE")
    put_proof!(peer, "OTHER-PROVIDER")
    assert {:ok, [%{agent_uid: ^uid, instance_ref: ref}]} = Vercel.list_instances(provider, :all)
    assert ref == first.instance_ref
    assert {:ok, [%{agent_uid: ^peer_uid}]} = Vercel.list_instances(peer_provider, :all)

    assert {:ok, token} = AgentWorkers.credential(first)
    spec = WorkerBootstrap.agent_worker_spec(provider, uid, first.generation, token)
    assert {:ok, ^ref} = Vercel.create_instance(provider, %{spec | instance_ref: ref})
    assert_proof!(first, "HOME-BEFORE-DELETE")

    assert {:ok, _} = Principals.delete_agent(uid)
    assert %AgentWorker{generation: nil} = await_worker_state!(uid, "absent")
    assert {:ok, []} = Vercel.list_instances(provider, uid)
    assert [%{"name" => home}] = drives!(provider, uid)
    assert home == ProviderKind.storage_name(provider.runtime.installation, uid)

    assert {:ok, _} = Principals.enable_agent(uid)
    assert :ok = AgentWorkers.request(uid)
    restored = await_worker_state!(uid, "ready")
    refute restored.generation == first.generation
    refute restored.instance_ref == first.instance_ref
    assert_proof!(restored, "HOME-BEFORE-DELETE")

    # Stop the VM outside reconciliation. This checks the platform's storage
    # boundary and the production disappearance path, not a fabricated row.
    put_proof!(restored, "HOME-BEFORE-VM-STOP")

    assert {:ok, _} =
             Client.request(
               provider,
               :post,
               "/v2/sandboxes/sessions/#{restored.instance_ref}/stop"
             )

    recovered = await_worker_state!(uid, "ready", restored.generation)
    assert_proof!(recovered, "HOME-BEFORE-VM-STOP")

    put_proof!(recovered, "HOME-BEFORE-IMAGE-CHANGE")
    :ok = Config.put(context.runtime |> Map.to_list() |> Keyword.put(:image, context.replacement))
    changed = await_worker_state!(uid, "ready", recovered.generation)
    assert changed.image == context.replacement
    assert_proof!(changed, "HOME-BEFORE-IMAGE-CHANGE")
    assert {:ok, _} = Principals.delete_agent(uid)
    assert {:ok, _} = Principals.delete_agent(uid)
    assert await_worker_state!(uid, nil) == nil
    assert {:ok, []} = Vercel.list_instances(provider, uid)
    assert drives!(provider, uid) == []
    assert_proof!(Repo.get!(AgentWorker, peer_uid), "OTHER-PROVIDER")
    assert {:ok, [%{generation: generation}]} = Vercel.list_instances(peer_provider, :all)
    assert generation == peer.generation
  end

  defp drives!(provider, uid) do
    name = ProviderKind.storage_name(provider.runtime.installation, uid)

    assert {:ok, drives} =
             Client.list(provider, "/v2/sandboxes/drives", "drives",
               projectId: provider.settings["projectId"],
               sortBy: "name",
               namePrefix: name
             )

    Enum.filter(drives, &(&1["name"] == name))
  end

  defp assert_worker_user!(provider, worker) do
    script = """
    test "$(id -u)" = 0
    ! command -v sudo
    pid=$(cat /run/ankole-worker.pid)
    test "$(awk '/^Uid:/ {print $2, $3, $4, $5}' /proc/$pid/status)" = '1000 1000 1000 1000'
    test "$(awk '/^NoNewPrivs:/ {print $2}' /proc/$pid/status)" = 1
    """

    path = "/v2/sandboxes/sessions/#{worker.instance_ref}/cmd"

    assert {:ok, %{"command" => %{"id" => id}}} =
             Client.request(provider, :post, path,
               json: %{command: "bash", args: ["-ec", script], sudo: false, wait: false}
             )

    assert {:ok, %{"command" => %{"exitCode" => 0}}} =
             Client.request(provider, :get, path <> "/" <> id, params: [wait: true])
  end
end
