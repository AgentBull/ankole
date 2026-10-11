defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.GenerationRecoveryTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{Providers, ReconcileJob, SweepJob}
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  # Only Engine HTTP is simulated. Shapes: moby/moby v23.0.6 api/swagger.yaml.
  setup do
    %{principal: agent} = agent_fixture()
    :ok = AgentWorkers.request(agent.uid)

    api = Ankole.AgentWorkerDockerHTTP.install(:timeout)
    %{uid: agent.uid, api: api}
  end

  test "uncertain create keeps its generation and credential across retries", %{
    uid: uid,
    api: api
  } do
    assert {:error, {:docker_api, 503, _}} = reconcile(uid)
    first = Repo.get!(AgentWorker, uid)
    assert first.state == "starting"
    assert first.generation != nil
    assert first.instance_seen_at == nil
    assert first.last_error =~ "platform unavailable"
    assert first.last_error_kind == "transient"
    assert %DateTime{} = first.create_sent_at
    assert {:ok, token} = AgentWorkers.credential(first)
    assert first.token_digest == :crypto.hash(:sha256, token)
    refute first.token_ciphertext == token

    Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid),
      set: [state_changed_at: DateTime.add(DateTime.utc_now(), -86_400)]
    )

    assert :ok = SweepJob.perform(%Oban.Job{args: %{}})
    assert Enum.any?(all_enqueued(worker: ReconcileJob), &(&1.args["agent_uid"] == uid))
    assert {:error, {:docker_api, 503, _}} = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation == first.generation
    assert Repo.get!(AgentWorker, uid).create_sent_at == first.create_sent_at
    Agent.update(api, &%{&1 | mode: :success})
    assert :ok = reconcile(uid)
    last = Repo.get!(AgentWorker, uid)
    assert last.generation == first.generation
    assert last.token_ciphertext == first.token_ciphertext
    assert last.instance_seen_at != nil
    assert length(Enum.uniq(create_names(api))) == 1
  end

  test "a lost create response and empty list retry the same named container", %{
    uid: uid,
    api: api
  } do
    Agent.update(api, &%{&1 | mode: :accepted_timeout, hidden: true})
    assert {:error, {:docker_api, 503, _}} = reconcile(uid)
    generation = Repo.get!(AgentWorker, uid).generation
    Agent.update(api, &%{&1 | mode: :success})
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation == generation

    assert Repo.get!(AgentWorker, uid).last_error ==
             "Waiting for provider to observe generation #{generation}"

    assert Repo.get!(AgentWorker, uid).last_error_kind == "pending"

    assert map_size(Agent.get(api, & &1.containers)) == 1
    assert length(create_names(api)) == 2
    assert length(Enum.uniq(create_names(api))) == 1
  end

  test "a configuration edit cannot change the launch settings of an uncertain generation", %{
    uid: uid,
    api: api
  } do
    provider_id = Repo.get!(AgentWorker, uid).provider_id

    assert {:ok, _} =
             Providers.update(provider_id, %{
               config: "network: bridge\nmemoryMiB: 512\nenv: {REVISION: first}\n"
             })

    assert {:error, {:docker_api, 503, _}} = reconcile(uid)
    first = Repo.get!(AgentWorker, uid)

    assert {:ok, _} =
             Providers.update(provider_id, %{
               config: """
               network: bridge
               memoryMiB: 1024
               env: {REVISION: second}
               endpoints:
                 aiGatewayUrl: https://next.example.test/api/v1/ai-gateway
               idleReleaseAfter: 1h
               """
             })

    # The retried create succeeds before the platform list sees it.
    Agent.update(api, &%{&1 | mode: :success, hidden: true})
    assert :ok = reconcile(uid)
    worker = Repo.get!(AgentWorker, uid)
    assert worker.generation == first.generation
    assert worker.instance_settings == first.instance_settings
    assert worker.settings_digest == first.settings_digest
    assert {:ok, %{}} = Providers.connection_endpoints(uid)
    [container] = Agent.get(api, &Map.values(&1.containers))
    assert container["Config"]["HostConfig"]["Memory"] == 512 * 1024 * 1024
    assert "REVISION=first" in container["Config"]["Env"]
    refute Enum.any?(container["Config"]["Env"], &String.contains?(&1, "next.example.test"))
    assert length(Enum.uniq(create_names(api))) == 1
  end

  test "deletion settles uncertain generation before storage and row deletion", %{
    uid: uid,
    api: api
  } do
    assert {:error, _} = reconcile(uid)
    first = Repo.get!(AgentWorker, uid)
    assert {:ok, token} = AgentWorkers.credential(first)
    assert :ok = AgentWorkers.mark_deleting_in_tx(Repo, uid)
    deleting = Repo.get!(AgentWorker, uid)
    assert deleting.generation == first.generation
    assert deleting.token_digest == first.token_digest
    assert {:error, :stale_worker_generation} = AgentWorkers.authenticate(uid, token)
    assert {:error, _} = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).state == "deleting"
    assert map_size(Agent.get(api, & &1.volumes)) == 2
    Agent.update(api, &%{&1 | mode: :success})
    assert :ok = reconcile(uid)
    assert Repo.get(AgentWorker, uid) == nil
    assert Agent.get(api, & &1.containers) == %{}
    assert Agent.get(api, & &1.volumes) == %{}
    assert length(Enum.uniq(create_names(api))) == 1
    calls = Agent.get(api, &Enum.reverse(&1.calls))

    container_delete =
      Enum.find_index(calls, fn {method, path} ->
        method == "DELETE" and String.contains?(path, "/containers/")
      end)

    volume_delete =
      Enum.find_index(calls, fn {method, path} ->
        method == "DELETE" and String.contains?(path, "/volumes/")
      end)

    assert container_delete < volume_delete
  end

  test "only a definite rejection gives up an unobserved generation", %{uid: uid, api: api} do
    assert {:error, _} = reconcile(uid)
    old = Repo.get!(AgentWorker, uid).generation
    Agent.update(api, &%{&1 | mode: :rejected})
    assert {:error, {:docker_api, 400, _}} = reconcile(uid)

    assert %AgentWorker{
             state: "absent",
             generation: nil,
             token_digest: nil,
             token_ciphertext: nil,
             instance_seen_at: nil,
             create_sent_at: nil,
             last_error_kind: "rejected"
           } = Repo.get!(AgentWorker, uid)

    Agent.update(api, &%{&1 | mode: :success})
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation != old
  end

  test "an observed instance disappearing ends its generation", %{uid: uid, api: api} do
    Agent.update(api, &%{&1 | mode: :success})
    assert :ok = reconcile(uid)
    old = Repo.get!(AgentWorker, uid)
    assert old.instance_seen_at != nil
    Agent.update(api, &%{&1 | containers: %{}})
    assert :ok = reconcile(uid)
    new = Repo.get!(AgentWorker, uid)
    assert new.generation != old.generation
    assert new.storage_ref == old.storage_ref
  end

  test "a deleting row without provider is removed without platform calls", %{uid: uid, api: api} do
    Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid), set: [provider_id: nil])
    assert :ok = AgentWorkers.mark_deleting_in_tx(Repo, uid)
    assert :ok = reconcile(uid)
    assert Repo.get(AgentWorker, uid) == nil
    assert Agent.get(api, & &1.calls) == []
  end

  defp reconcile(uid),
    do:
      ReconcileJob.perform(%Oban.Job{
        args: %{"agent_uid" => uid, "tenant_id" => Repo.tenant_id!()}
      })

  defp create_names(api),
    do: Agent.get(api, fn s -> for {"CREATE", name} <- s.calls, do: name end)
end
