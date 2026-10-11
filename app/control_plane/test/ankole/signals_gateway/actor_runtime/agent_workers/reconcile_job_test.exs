defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ReconcileJobTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.AgentWorkerDockerHTTP
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{Config, Providers, ReconcileJob}
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission
  alias Ankole.SignalsGateway.ActorRuntimeCase

  setup do
    %{principal: agent} = agent_fixture()
    :ok = AgentWorkers.request(agent.uid)
    %{uid: agent.uid, api: AgentWorkerDockerHTTP.install()}
  end

  test "keeps one waiting job per Agent with bounded retry backoff", %{uid: uid} do
    unique = ReconcileJob.__opts__()[:unique]
    assert unique[:keys] == [:agent_uid]
    assert unique[:period] == :infinity
    assert Enum.sort(unique[:states]) == Enum.sort([:available, :scheduled, :retryable])
    assert ReconcileJob.backoff(%Oban.Job{attempt: 3}) == 8
    assert ReconcileJob.backoff(%Oban.Job{attempt: 19}) == 60
    :ok = ReconcileJob.enqueue(uid)
    :ok = ReconcileJob.enqueue(uid)
    assert [_job] = all_enqueued(worker: ReconcileJob, args: %{agent_uid: uid})
  end

  test "idle release deletes the instance, keeps both volumes, and wakes in a new generation", %{
    uid: uid,
    api: api
  } do
    assert :ok = reconcile(uid)
    first = Repo.get!(AgentWorker, uid)
    assert first.generation =~ ~r/\A[a-z2-7]{10}\z/
    assert {:ok, token} = AgentWorkers.credential(first)
    assert first.token_digest == :crypto.hash(:sha256, token)
    join!(uid)
    put_idle_release_after(uid, 1)
    set_row!(uid, wanted_until: nil)
    heartbeat!(uid, idle_for_ms: 5_000)
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).state == "draining"
    assert Enum.any?(Agent.get(api, & &1.signals), fn {_name, signal} -> signal == "SIGTERM" end)
    close_connection!(uid)
    assert :ok = reconcile(uid)

    assert %AgentWorker{state: "absent", generation: nil, token_ciphertext: nil} =
             Repo.get!(AgentWorker, uid)

    assert Agent.get(api, & &1.containers) == %{}
    assert map_size(Agent.get(api, & &1.volumes)) == 2
    :ok = AgentWorkers.request(uid)
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation != first.generation
  end

  test "an open workspace prevents release until its slot is closed", %{uid: uid} do
    assert :ok = reconcile(uid)
    join!(uid)
    put_idle_release_after(uid, 1)
    set_row!(uid, wanted_until: nil)
    heartbeat!(uid, idle_for_ms: 5_000)
    heartbeat!(uid, idle_for_ms: 0, active_slots: 1)
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).state == "ready"

    heartbeat!(uid, idle_for_ms: 5_000)

    assert :ok = reconcile(uid)

    assert %AgentWorker{state: "draining", drain_reason: "idle_release"} =
             Repo.get!(AgentWorker, uid)
  end

  test "an image replacement waits for the connection to end before allocating a generation", %{
    uid: uid,
    api: api
  } do
    assert :ok = reconcile(uid)
    first = Repo.get!(AgentWorker, uid)
    join!(uid)
    set_row!(uid, image: "ankole-agent-computer:old")
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation == first.generation
    close_connection!(uid)
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation != first.generation

    refute Enum.any?(Agent.get(api, & &1.calls), fn {method, path} ->
             method == "DELETE" and String.contains?(path, "/volumes/")
           end)
  end

  test "connection addresses change only when an idle Worker gets a new generation", %{uid: uid} do
    provider_id = Repo.get!(AgentWorker, uid).provider_id

    old_endpoints = %{
      "aiGatewayUrl" => "https://old.example.test/api/v1/ai-gateway",
      "relayOrigin" => "https://old.example.test"
    }

    assert {:ok, _} =
             Providers.update(provider_id, %{
               config: Ankole.JSON.encode!(%{network: "bridge", endpoints: old_endpoints})
             })

    assert :ok = reconcile(uid)
    join!(uid)
    first = Repo.get!(AgentWorker, uid)
    set_row!(uid, load: %{"active_tasks" => 1, "idle_for_ms" => 0})
    next_endpoints = %{"aiGatewayUrl" => "https://next.example.test/api/v1/ai-gateway"}

    assert {:ok, _} =
             Providers.update(provider_id, %{
               config: Ankole.JSON.encode!(%{network: "bridge", endpoints: next_endpoints})
             })

    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation == first.generation
    assert Repo.get!(AgentWorker, uid).state == "ready"
    assert {:ok, ^old_endpoints} = Providers.connection_endpoints(uid)

    assert {:ok, response} =
             Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker.handle_request(
               uid,
               %FabricProto.AIGatewayAPIKeyRequest{},
               %{request_id: "busy-endpoint"}
             )

    assert response.base_url == old_endpoints["aiGatewayUrl"]

    heartbeat!(uid, idle_for_ms: 0)
    assert :ok = reconcile(uid)
    close_connection!(uid)
    assert :ok = reconcile(uid)
    refute Repo.get!(AgentWorker, uid).generation == first.generation
    assert {:ok, ^next_endpoints} = Providers.connection_endpoints(uid)

    assert {:ok, response} =
             Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker.handle_request(
               uid,
               %FabricProto.AIGatewayAPIKeyRequest{},
               %{request_id: "replaced-endpoint"}
             )

    assert response.base_url == next_endpoints["aiGatewayUrl"]
  end

  test "a connected row waits for admission to release its Turns when its instance exits", %{
    uid: uid,
    api: api
  } do
    assert :ok = reconcile(uid)
    join!(uid)
    first = Repo.get!(AgentWorker, uid)

    Agent.update(api, fn state ->
      %{
        state
        | containers:
            Map.new(state.containers, fn {name, c} -> {name, Map.put(c, "State", "exited")} end)
      }
    end)

    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).transport_route == first.transport_route
    close_connection!(uid)
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation != first.generation
  end

  test "termination never advances to a new generation while the instance remains", %{
    uid: uid,
    api: api
  } do
    assert :ok = reconcile(uid)
    first = Repo.get!(AgentWorker, uid)
    Agent.update(api, &%{&1 | hold_kill: true})

    set_row!(uid,
      state: "draining",
      drain_reason: "replacement",
      state_changed_at: DateTime.add(DateTime.utc_now(), -120)
    )

    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation == first.generation
    assert map_size(Agent.get(api, & &1.containers)) == 1
    assert [{_, "SIGKILL"}] = Agent.get(api, & &1.signals)
    assert Repo.get!(AgentWorker, uid).last_error =~ "Waiting for instance"
    assert Repo.get!(AgentWorker, uid).last_error =~ first.generation
    assert Repo.get!(AgentWorker, uid).last_error_kind == "pending"

    Agent.update(api, &%{&1 | hold_kill: false})
    set_row!(uid, wanted_until: nil)
    assert :ok = reconcile(uid)
    assert :ok = reconcile(uid)
    assert %AgentWorker{state: "absent", last_error: nil} = Repo.get!(AgentWorker, uid)
    assert {:wait, :starting} = AgentWorkers.workspace_status(uid)

    :ok = AgentWorkers.request(uid)
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation != first.generation
  end

  test "readiness rebuild deletes cache after the observed instance disappears", %{
    uid: uid,
    api: api
  } do
    observe_since!(minutes_ago: 11)
    assert :ok = reconcile(uid)
    old = Repo.get!(AgentWorker, uid).generation
    age_state!(uid, 11)
    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).generation != old
    deleted = for {"DELETE", "/volumes/" <> name} <- Agent.get(api, & &1.calls), do: name
    assert [cache] = deleted
    assert String.ends_with?(cache, "-cache")
  end

  test "a control-plane outage does not immediately rebuild stale Workers", %{uid: uid, api: api} do
    assert :ok = reconcile(uid)
    join!(uid)
    first = Repo.get!(AgentWorker, uid)
    set_row!(uid, state: "stale", transport_route: nil)
    age_state!(uid, 60)
    observe_since!(minutes_ago: 1)
    assert :ok = reconcile(uid)
    assert %AgentWorker{state: "stale", generation: generation} = Repo.get!(AgentWorker, uid)
    assert generation == first.generation
    assert Agent.get(api, & &1.signals) == []
  end

  test "shows platform reasons while a Worker is not ready", %{uid: uid, api: api} do
    assert :ok = reconcile(uid)

    Agent.update(api, fn state ->
      %{
        state
        | containers:
            Map.new(state.containers, fn {name, c} ->
              {name, Map.put(c, "Status", "Worker failed to start")}
            end)
      }
    end)

    assert :ok = reconcile(uid)
    assert Repo.get!(AgentWorker, uid).last_error == "Worker failed to start"
    assert Repo.get!(AgentWorker, uid).last_error_kind == "transient"
  end

  defp reconcile(uid), do: perform_job(ReconcileJob, %{"agent_uid" => uid})

  defp join!(uid) do
    route = "reconcile-route-#{System.unique_integer([:positive])}"
    {:ok, _worker} = ActorRuntimeCase.admit_worker(route, %{worker_id: uid})
  end

  defp set_row!(uid, changes),
    do: Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^uid), set: changes)

  defp heartbeat!(agent_uid, opts) do
    idle_for_ms = Keyword.fetch!(opts, :idle_for_ms)
    active = Keyword.get(opts, :active_slots, 0)
    worker = Repo.get!(AgentWorker, agent_uid)

    {:ok, _worker} =
      ActorRuntime.handle_worker_heartbeat(
        struct!(FabricProto.AgentComputerWorkerHeartbeat,
          incarnation_id: worker.incarnation_id,
          max_slots: 4,
          available_slots: 4 - active,
          active_slots: active,
          active_tasks: active,
          idle_for_ms: idle_for_ms
        ),
        %{transport_route: worker.transport_route, worker_id: agent_uid}
      )
  end

  # What the Channel does when the Worker process exits and its socket closes.
  defp close_connection!(agent_uid) do
    %AgentWorker{transport_route: route} = Repo.get!(AgentWorker, agent_uid)
    assert {:ok, :marked_stale} = WorkerAdmission.mark_route_unusable(route, :socket_closed)
  end

  defp put_idle_release_after(uid, seconds) do
    worker = Repo.get!(AgentWorker, uid)
    {:ok, provider} = Providers.fetch(worker.provider_id)

    {:ok, _} =
      Providers.update(provider.provider_id, %{
        config: provider.config <> "\nidleReleaseAfter: #{seconds}s\n"
      })
  end

  # This node observes Workers since `minutes` ago, as one that started then.
  defp observe_since!(minutes_ago: minutes) do
    {:ok, previous} = Config.fetch()
    opts = Application.fetch_env!(:ankole, AgentWorkers)
    since = DateTime.add(DateTime.utc_now(), -minutes, :minute)
    :ok = Config.put(Keyword.put(opts, :observing_since, since))
    on_exit(fn -> Config.put(Keyword.put(opts, :observing_since, previous.observing_since)) end)
  end

  defp age_state!(agent_uid, minutes) do
    Repo.update_all(
      from(w in AgentWorker,
        where: w.agent_uid == ^agent_uid,
        update: [
          set: [
            state_changed_at: fragment("now() - make_interval(mins => ?)", ^minutes),
            instance_seen_at: fragment("now() - make_interval(mins => ?)", ^minutes)
          ]
        ]
      ),
      []
    )
  end
end
