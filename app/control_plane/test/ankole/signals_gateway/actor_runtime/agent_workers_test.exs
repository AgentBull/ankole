defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkersTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Principals
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers
  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ReconcileJob
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntimeCase

  setup do
    %{principal: agent} = agent_fixture()
    :ok = ActorRuntimeCase.provision_worker(agent.uid)
    {:ok, agent_uid: agent.uid, token: Process.get({:worker_token, agent.uid})}
  end

  describe "credentials" do
    test "retries decrypt the credential and only the current generation's token connects", ctx do
      assert %AgentWorker{token_digest: digest, token_ciphertext: ciphertext} =
               worker = Repo.get!(AgentWorker, ctx.agent_uid)

      assert digest == :crypto.hash(:sha256, ctx.token)
      refute ciphertext == ctx.token
      assert {:ok, token} = AgentWorkers.credential(worker)
      assert token == ctx.token
      generation = worker.generation

      assert {:ok, %{generation: ^generation, tenant_id: tenant_id}} =
               AgentWorkers.authenticate(ctx.agent_uid, ctx.token)

      assert tenant_id == ctx.tenant.id

      assert {:error, :invalid_worker_credential} =
               AgentWorkers.authenticate(ctx.agent_uid, ctx.token <> "x")

      # A new generation replaces the credential.
      {:ok, credential} = AgentWorkers.issue_credential(ctx.agent_uid, "next-generation")
      set_row!(ctx.agent_uid, [generation: "next-generation"] ++ Map.to_list(credential))

      assert {:error, :invalid_worker_credential} =
               AgentWorkers.authenticate(ctx.agent_uid, ctx.token)
    end

    test "one Agent's credential cannot connect as another Agent", ctx do
      %{principal: other} = agent_fixture()
      :ok = ActorRuntimeCase.provision_worker(other.uid)

      assert {:error, :invalid_worker_credential} =
               AgentWorkers.authenticate(other.uid, ctx.token)
    end

    test "a row that may not run a process refuses every connection", ctx do
      for state <- ["paused", "draining"] do
        set_row!(ctx.agent_uid, state: state)

        assert {:error, :stale_worker_generation} =
                 AgentWorkers.authenticate(ctx.agent_uid, ctx.token)
      end

      :ok = AgentWorkers.mark_deleting_in_tx(Repo, ctx.agent_uid)

      assert {:error, :stale_worker_generation} =
               AgentWorkers.authenticate(ctx.agent_uid, ctx.token)

      assert {:error, :unknown_worker} = AgentWorkers.authenticate("missing-agent", ctx.token)
      assert {:error, :invalid_worker_credential} = AgentWorkers.authenticate(ctx.agent_uid, "")
    end

    test "rotating the installation key does not touch Worker credentials", ctx do
      {:ok, _key} =
        AppConfigure.put_global(WorkerAuthKey.definition(), "rotated-installation-key")

      on_exit(fn -> AppConfigure.delete_global(WorkerAuthKey.definition()) end)

      generation = Repo.get!(AgentWorker, ctx.agent_uid).generation

      assert {:ok, %{generation: ^generation, tenant_id: tenant_id}} =
               AgentWorkers.authenticate(ctx.agent_uid, ctx.token)

      assert tenant_id == ctx.tenant.id
    end
  end

  describe "admission" do
    test "a join on a starting, stale, or ready row records the route and incarnation", ctx do
      assert {:ok,
              %AgentWorker{state: "ready", transport_route: "route-1", incarnation_id: "inc-1"}} =
               join_worker(ctx.agent_uid, "route-1", "inc-1")

      set_row!(ctx.agent_uid, state: "stale", transport_route: nil)

      assert {:ok, %AgentWorker{state: "ready", transport_route: "route-2"}} =
               join_worker(ctx.agent_uid, "route-2", "inc-1")

      # The same process on a new connection only moves the route.
      assert {:ok, %AgentWorker{transport_route: "route-3", incarnation_id: "inc-1"}} =
               join_worker(ctx.agent_uid, "route-3", "inc-1")
    end

    test "a join on a paused, draining, or deleted Worker is refused", ctx do
      for state <- ["paused", "draining"] do
        set_row!(ctx.agent_uid, state: state)
        assert {:error, :stale_worker_generation} = join_worker(ctx.agent_uid, "route-x", "inc-x")
      end

      :ok = AgentWorkers.mark_deleting_in_tx(Repo, ctx.agent_uid)
      assert {:error, :stale_worker_generation} = join_worker(ctx.agent_uid, "route-x", "inc-x")
    end

    test "a join is refused when the generation was created for another protocol", ctx do
      set_row!(ctx.agent_uid, protocol_version: RuntimeFabric.protocol_version() - 1)
      assert {:error, :protocol_mismatch} = join_worker(ctx.agent_uid, "route-1", "inc-1")
    end

    test "a disabled Agent's Worker can still connect", ctx do
      {:ok, _principal} = Ankole.PrincipalsFixtures.disable_principal_fixture(ctx.agent_uid)
      assert {:ok, %AgentWorker{state: "ready"}} = join_worker(ctx.agent_uid, "route-1", "inc-1")
    end

    test "a heartbeat renews only the admitted connection and never restores a stale row", ctx do
      {:ok, _worker} = join_worker(ctx.agent_uid, "route-1", "inc-1")
      assert {:ok, %AgentWorker{state: "ready"}} = heartbeat(ctx.agent_uid, "route-1", "inc-1")

      assert {:error, :stale_transport_route} = heartbeat(ctx.agent_uid, "route-other", "inc-1")
      assert {:error, :stale_transport_route} = heartbeat(ctx.agent_uid, "route-1", "inc-other")

      assert {:ok, _result} =
               Ankole.SignalsGateway.ActorRuntime.WorkerAdmission.mark_route_unusable(
                 "route-1",
                 :socket_closed
               )

      assert %AgentWorker{state: "stale", transport_route: nil} =
               Repo.get!(AgentWorker, ctx.agent_uid)

      assert {:error, :stale_transport_route} = heartbeat(ctx.agent_uid, "route-1", "inc-1")
      assert %AgentWorker{state: "stale"} = Repo.get!(AgentWorker, ctx.agent_uid)
    end
  end

  describe "placement" do
    test "takes one slot of a ready Worker and tells why it cannot", ctx do
      assert {:error, :agent_worker_unavailable} = reserve(ctx.agent_uid)

      {:ok, _worker} = join_worker(ctx.agent_uid, "route-1", "inc-1", available_slots: 1)

      assert {:ok, %AgentWorker{capacity: %{"available_slots" => 0}}} =
               reserve(ctx.agent_uid)

      assert {:error, :no_worker_capacity} = reserve(ctx.agent_uid)

      {:ok, _principal} = Ankole.PrincipalsFixtures.disable_principal_fixture(ctx.agent_uid)
      assert {:error, :agent_not_active} = reserve(ctx.agent_uid)
    end
  end

  describe "requests" do
    test "keep the Worker wanted for a while and schedule its reconciliation", ctx do
      assert :ok = AgentWorkers.request(ctx.agent_uid)

      assert %AgentWorker{wanted_until: %DateTime{} = until} =
               Repo.get!(AgentWorker, ctx.agent_uid)

      assert DateTime.diff(until, DateTime.utc_now(), :second) in 290..300
      assert_enqueued(worker: ReconcileJob, args: %{agent_uid: ctx.agent_uid})
    end

    test "do not wake a deleted Agent's Worker", ctx do
      :ok = AgentWorkers.mark_deleting_in_tx(Repo, ctx.agent_uid)
      assert :ok = AgentWorkers.request(ctx.agent_uid)
      assert %AgentWorker{wanted_until: nil} = Repo.get!(AgentWorker, ctx.agent_uid)
    end
  end

  test "disabling and deleting an Agent reconcile its Worker", ctx do
    {:ok, _principal} = Ankole.PrincipalsFixtures.disable_principal_fixture(ctx.agent_uid)
    assert_enqueued(worker: ReconcileJob, args: %{agent_uid: ctx.agent_uid})
    Repo.delete_all(Oban.Job)

    {:ok, _principal} = Principals.delete_agent(ctx.agent_uid)
    assert %AgentWorker{state: "deleting"} = Repo.get!(AgentWorker, ctx.agent_uid)
    assert_enqueued(worker: ReconcileJob, args: %{agent_uid: ctx.agent_uid})
  end

  defp join_worker(agent_uid, route, incarnation_id, opts \\ []) do
    slots = Keyword.get(opts, :available_slots, 4)

    ActorRuntime.admit_join(
      %{
        incarnation_id: incarnation_id,
        max_slots: max(slots, 1),
        available_slots: slots
      },
      %{
        transport_route: route,
        worker_id: agent_uid,
        generation: Repo.get!(AgentWorker, agent_uid).generation
      }
    )
  end

  defp heartbeat(agent_uid, route, incarnation_id) do
    ActorRuntime.handle_worker_heartbeat(
      %FabricProto.AgentComputerWorkerHeartbeat{
        incarnation_id: incarnation_id,
        max_slots: 4,
        available_slots: 4
      },
      %{transport_route: route, worker_id: agent_uid}
    )
  end

  defp reserve(agent_uid),
    do: Repo.transact(fn repo -> AgentWorkers.reserve_slot_in_tx(repo, agent_uid) end)

  defp set_row!(agent_uid, changes) do
    {1, _rows} =
      Repo.update_all(from(worker in AgentWorker, where: worker.agent_uid == ^agent_uid),
        set: changes
      )
  end
end
