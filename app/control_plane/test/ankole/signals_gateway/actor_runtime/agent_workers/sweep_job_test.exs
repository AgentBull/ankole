defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.SweepJobTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{
    Docker,
    PrepareImageJob,
    Providers,
    ReconcileJob,
    SweepJob
  }

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Provider
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerBootstrap

  @minute 60_000

  setup do
    api = Ankole.AgentWorkerDockerHTTP.install()
    row = worker_provider_fixture(%{config: "network: bridge\nidleReleaseAfter: 15m\n"})
    {:ok, provider} = Providers.load(row)
    %{provider: provider, api: api}
  end

  test "enqueues lifecycle work and idle Workers while leaving active workspaces alone", %{
    provider: provider
  } do
    idle =
      agent_in!(provider, "ready", load: %{"active_tasks" => 0, "idle_for_ms" => 16 * @minute})

    busy = agent_in!(provider, "ready", load: %{"active_tasks" => 1, "idle_for_ms" => 0})
    wanted = agent_in!(provider, "absent", wanted: true)
    unwanted = agent_in!(provider, "absent")
    starting = agent_in!(provider, "starting")
    stale = agent_in!(provider, "stale")
    draining = agent_in!(provider, "draining")
    paused = agent_in!(provider, "paused")
    other_image = agent_in!(provider, "paused", image: "worker:old")
    other_settings = agent_in!(provider, "ready", settings_digest: "previous")
    disabled = agent_in!(provider, "ready")
    {:ok, _principal} = Ankole.PrincipalsFixtures.disable_principal_fixture(disabled)

    turn =
      agent_in!(provider, "ready",
        load: %{"active_slots" => 1, "active_tasks" => 1, "idle_for_ms" => 0}
      )

    warm = agent_in!(provider, "absent")
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(SweepJob, %{})
    assert_enqueued(worker: PrepareImageJob, args: %{provider_id: provider.provider_id})

    for uid <- [
          idle,
          wanted,
          starting,
          stale,
          draining,
          other_image,
          other_settings,
          disabled
        ] do
      assert_enqueued(worker: ReconcileJob, args: %{agent_uid: uid})
    end

    for uid <- [busy, unwanted, paused, warm, turn] do
      refute_enqueued(worker: ReconcileJob, args: %{agent_uid: uid})
    end

    {:ok, _row} =
      Providers.update(provider.provider_id, %{
        config: "network: bridge\nidleReleaseAfter: never\n"
      })

    Repo.delete_all(Oban.Job)
    assert :ok = perform_job(SweepJob, %{})
    refute_enqueued(worker: ReconcileJob, args: %{agent_uid: idle})
  end

  test "deletes orphan instances only in configured providers and queues observations for reconciliation",
       %{provider: provider, api: api} do
    orphan = unique_uid("orphan")
    create_object!(provider, orphan, "gen-orphan")
    foreign_provider = %{provider | provider_id: "another-installation-provider"}
    foreign = unique_uid("foreign")
    create_object!(foreign_provider, foreign, "gen-foreign")
    mismatched = agent_in!(provider, "ready")
    create_object!(provider, mismatched, "gen-stray")
    missing = agent_in!(provider, "ready")
    started_by_hand = agent_in!(provider, "paused")
    generation = Repo.get!(AgentWorker, started_by_hand).generation
    create_object!(provider, started_by_hand, generation)
    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(SweepJob, %{"objects" => true})
    assert {:ok, [%{phase: :exited}]} = Docker.list_instances(provider, orphan)
    assert :ok = perform_job(SweepJob, %{"objects" => true})
    assert {:ok, []} = Docker.list_instances(provider, orphan)
    assert {:ok, [%{phase: :running}]} = Docker.list_instances(foreign_provider, foreign)

    assert Enum.all?(Agent.get(api, & &1.signals), fn {name, _signal} ->
             not String.ends_with?(name, "gen-foreign")
           end)

    for uid <- [mismatched, missing, started_by_hand] do
      assert_enqueued(worker: ReconcileJob, args: %{agent_uid: uid})
    end
  end

  test "one invalid stored provider does not stop another provider or unassigned deletion", %{
    provider: provider
  } do
    valid = agent_in!(provider, "starting")
    broken = worker_provider_fixture()
    {:ok, broken_provider} = Providers.load(broken)
    affected = agent_in!(broken_provider, "ready")

    Repo.update_all(from(p in Provider, where: p.id == ^broken.id),
      set: [config: "unknown: true\n"]
    )

    unassigned = unique_uid("unassigned")

    Repo.insert!(%AgentWorker{
      agent_uid: unassigned,
      state: "deleting",
      state_changed_at: DateTime.utc_now(:microsecond)
    })

    Repo.delete_all(Oban.Job)

    assert :ok = perform_job(SweepJob, %{"objects" => true})

    for uid <- [valid, affected, unassigned] do
      assert_enqueued(worker: ReconcileJob, args: %{agent_uid: uid})
    end

    assert {:error, {:invalid_worker_provider_config, _}} =
             perform_job(ReconcileJob, %{agent_uid: affected})

    assert Repo.get!(AgentWorker, affected).last_error =~ "unknown"
    assert Repo.get!(AgentWorker, affected).last_error_kind == "rejected"
  end

  defp agent_in!(provider, state, opts \\ []) do
    %{principal: agent} = agent_fixture(%{worker_provider_id: provider.provider_id})
    generation = if state in ["absent", "deleting"], do: nil, else: unique_uid("gen")

    credential =
      if generation do
        {:ok, credential} = AgentWorkers.issue_credential(agent.uid, generation)
        credential
      else
        %{token_digest: nil, token_ciphertext: nil}
      end

    route = if state in ["ready", "draining"], do: unique_uid("sweep-route")
    now = DateTime.utc_now(:microsecond)

    {1, _} =
      Repo.update_all(from(w in AgentWorker, where: w.agent_uid == ^agent.uid),
        set: [
          state: state,
          generation: generation,
          state_changed_at: now,
          token_digest: credential.token_digest,
          token_ciphertext: credential.token_ciphertext,
          image: generation && Keyword.get(opts, :image, provider.runtime.image),
          protocol_version: generation && provider.runtime.protocol_version,
          settings_digest:
            generation && Keyword.get(opts, :settings_digest, provider.settings_digest),
          transport_route: route,
          incarnation_id: route && "incarnation-" <> route,
          load: Keyword.get(opts, :load, %{}),
          last_worker_heartbeat_at: route && now,
          wanted_until: if(Keyword.get(opts, :wanted, false), do: DateTime.add(now, 300, :second))
        ]
      )

    agent.uid
  end

  defp create_object!(provider, agent_uid, generation) do
    spec = WorkerBootstrap.agent_worker_spec(provider, agent_uid, generation, "token")
    assert {:ok, nil} = Docker.create_instance(provider, spec)
  end
end
