defmodule Ankole.CloudflareWorkerStorageIntegrationTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.WorkerStorageFixtures

  alias Ankole.Principals
  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Cloudflare
  alias Ankole.AgentWorkers.Config
  alias Ankole.AgentWorkers.Providers

  alias Ankole.AgentWorkers.AgentWorker
  alias Ankole.AgentWorkers.WorkerBootstrap

  @moduletag cloud: true, sandbox: false, timeout: 1_800_000

  setup %{tenant: tenant} do
    adapter_url = System.fetch_env!("ANKOLE_CLOUDFLARE_TEST_ADAPTER_URL")
    token = System.fetch_env!("ANKOLE_CLOUDFLARE_TEST_ADAPTER_TOKEN")
    origin = System.fetch_env!("ANKOLE_CLOUDFLARE_TEST_CP_ORIGIN")
    image = System.fetch_env!("ANKOLE_CLOUDFLARE_TEST_IMAGE")
    replacement = System.fetch_env!("ANKOLE_CLOUDFLARE_TEST_REPLACEMENT_IMAGE")
    port = System.fetch_env!("ANKOLE_CLOUDFLARE_TEST_CP_PORT") |> String.to_integer()
    refute image == replacement

    {:ok, previous} = Config.fetch()
    :ok = Config.put(previous |> Map.to_list() |> Keyword.put(:image, image))
    on_exit(fn -> Config.put(Map.to_list(previous)) end)
    Ankole.E2E.Harness.start_ai_gateway_test_http_server!(port)

    %{principal: owner} = human_fixture()

    config =
      Ankole.JSON.encode!(%{
        adapterUrl: adapter_url,
        instance: "standard-3",
        idleReleaseAfter: "never",
        endpoints: %{
          runtimeFabricUrl:
            String.replace_prefix(origin, "https://", "wss://") <>
              "/runtime-fabric/worker",
          relayOrigin: origin,
          aiGatewayUrl: origin <> "/api/v1/ai-gateway"
        }
      })

    {uids, ids} =
      storage_agents!("cloudflare", Ankole.Ecto.UUIDv7.autogenerate(), owner.uid, config, %{
        "adapterToken" => token
      })

    on_exit(fn ->
      Repo.put_tenant_id(tenant.id)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn -> cleanup_storage!(uids, ids, owner.uid) end)

      cleanup_tenant!(tenant)
    end)

    %{uids: uids, replacement: replacement, runtime: previous}
  end

  test "real directory backups survive instance deletion and image replacement", context do
    [uid, peer_uid] = context.uids
    first = await_worker_state!(uid, :ready)
    peer = await_worker_state!(peer_uid, :ready)
    {:ok, provider} = Providers.load(first.provider_id)
    {:ok, peer_provider} = Providers.load(peer.provider_id)

    put_proof!(first, "proof.txt", "HOME-BEFORE-DELETE")
    put_proof!(peer, "proof.txt", "OTHER-PROVIDER")
    assert {:ok, [own]} = Cloudflare.list_instances(provider, :all)
    assert own.agent_uid == uid
    assert {:ok, [other]} = Cloudflare.list_instances(peer_provider, :all)
    assert other.agent_uid == peer_uid

    assert {:ok, token} = AgentWorkers.credential(first)

    spec =
      WorkerBootstrap.agent_worker_spec(provider, uid, first.generation, token, first.storage_ref)

    assert {:ok, nil} = Cloudflare.create_instance(provider, spec)
    assert {:ok, [repeated]} = Cloudflare.list_instances(provider, uid)
    assert repeated.generation == first.generation
    assert repeated.started_at == own.started_at
    assert_proof!(first, "HOME-BEFORE-DELETE")

    assert {:ok, _} = Principals.delete_agent(uid)
    absent = await_worker_state!(uid, :absent)
    assert absent.generation == nil
    assert is_map(absent.storage_ref)
    assert {:ok, []} = Cloudflare.list_instances(provider, uid)
    assert {:ok, ref, reason} = Cloudflare.current_storage_ref(provider, uid)
    assert ref == absent.storage_ref
    assert reason == absent.last_error
    assert {:rejected, _reason} = Cloudflare.create_instance(provider, spec)
    assert {:ok, ^ref, ^reason} = Cloudflare.current_storage_ref(provider, uid)
    assert {:ok, []} = Cloudflare.list_instances(provider, uid)

    assert {:ok, _} = Principals.enable_agent(uid)
    assert :ok = AgentWorkers.request(uid)
    restored = await_worker_state!(uid, :ready)
    refute restored.generation == first.generation
    assert_proof!(restored, "HOME-BEFORE-DELETE")
    put_proof!(restored, "proof.txt", "HOME-BEFORE-IMAGE-CHANGE")

    :ok =
      Config.put(context.runtime |> Map.to_list() |> Keyword.put(:image, context.replacement))

    changed = await_worker_state!(uid, :ready, restored.generation)
    assert changed.image == context.replacement
    assert_proof!(changed, "HOME-BEFORE-IMAGE-CHANGE")

    assert {:ok, _} = Principals.delete_agent(uid)
    assert {:ok, _} = Principals.delete_agent(uid)
    assert await_worker_state!(uid, nil) == nil
    assert {:ok, []} = Cloudflare.list_instances(provider, uid)
    assert {:ok, nil, nil} = Cloudflare.current_storage_ref(provider, uid)
    assert_proof!(Repo.get_by!(AgentWorker, agent_uid: peer_uid), "OTHER-PROVIDER")
    assert {:ok, [remaining]} = Cloudflare.list_instances(peer_provider, :all)
    assert remaining.agent_uid == peer_uid
    assert remaining.generation == peer.generation
  end
end
