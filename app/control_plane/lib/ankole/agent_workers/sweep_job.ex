defmodule Ankole.AgentWorkers.SweepJob do
  @moduledoc """
  Finds pending Worker work and provider-scoped orphan instances.

  Each provider is loaded independently. A bad configuration must not stop
  other providers. An unobserved starting generation is retried, never
  declared absent by a sweep. Only reconciliation can settle a generation.
  """

  use Ankole.Job, tenancy: :site, queue: :agent_workers, max_attempts: 1
  alias Ankole.{Logging, Principals, Repo}
  alias Ankole.AgentWorkers

  alias Ankole.AgentWorkers.Decision
  alias Ankole.AgentWorkers.ProviderKind
  alias Ankole.AgentWorkers.PrepareImageJob
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.ReconcileJob

  alias Ankole.AgentWorkers.Providers.Configuration

  @impl true
  def run(job), do: sweep(job)

  defp sweep(%Oban.Job{args: args}) do
    nil
    |> AgentWorkers.provider_workers()
    |> Enum.filter(&(&1.state == :deleting))
    |> Enum.each(&ReconcileJob.enqueue/1)

    Enum.each(Providers.list(), fn row ->
      case Providers.load(row) do
        {:ok, provider} ->
          PrepareImageJob.enqueue(provider)
          candidates(provider) |> Enum.each(&ReconcileJob.enqueue/1)
          if Map.get(args, "objects"), do: sweep_objects(provider)

        {:error, _reason} ->
          # Reconciliation writes this provider's failure to each affected row.
          row.provider_id
          |> AgentWorkers.provider_workers()
          |> Enum.each(&ReconcileJob.enqueue/1)
      end
    end)

    :ok
  end

  # Only the inventory read crosses tenants. The Agent and Turn facts are read
  # in the tenant of each row, and provider I/O runs with no query bypass.
  defp candidates(provider) do
    now = Repo.now!()
    idle_ms = Configuration.duration_ms(provider.settings["idleReleaseAfter"])

    {due, others} =
      provider.provider_id
      |> AgentWorkers.provider_workers()
      |> Enum.split_with(&lifecycle_due?(&1, provider))

    agent_due =
      others
      |> Enum.filter(&(&1.state in [:absent, :paused, :ready]))
      |> Enum.group_by(& &1.tenant_id)
      |> Enum.flat_map(fn {tenant_id, workers} ->
        Repo.with_tenant(tenant_id, fn -> agent_due(workers, now, idle_ms) end)
      end)

    due ++ agent_due
  end

  # Work that the Worker row alone shows: a lifecycle step in progress or a
  # generation with an old launch target.
  defp lifecycle_due?(worker, provider) do
    worker.state in [:starting, :stale, :draining, :deleting] or
      (not is_nil(worker.generation) and
         (worker.image != provider.runtime.image or
            worker.protocol_version != provider.runtime.protocol_version or
            worker.settings_digest != provider.settings_digest))
  end

  # Work that also depends on the Agent state and on its running Turns.
  defp agent_due(workers, now, idle_ms) do
    active = MapSet.new(Principals.list_active_agents(), & &1.principal.uid)

    waiting =
      for worker <- workers,
          worker.state != :ready,
          worker.agent_uid in active,
          do: worker.agent_uid

    running = if waiting == [], do: MapSet.new(), else: AgentWorkers.running_turn_agents(waiting)

    Enum.filter(workers, fn
      %{state: :ready} = worker ->
        worker.agent_uid not in active or idle?(worker, idle_ms) or
          heartbeat_expired?(worker, now)

      worker ->
        worker.agent_uid in active and
          (worker.initial_start_pending or wanted?(worker, now) or
             (worker.load["active_slots"] || 0) > 0 or worker.agent_uid in running)
    end)
  end

  defp idle?(_worker, :never), do: false

  defp idle?(%{load: load}, idle_ms),
    do: (load["active_tasks"] || -1) == 0 and (load["idle_for_ms"] || 0) >= idle_ms

  defp wanted?(%{wanted_until: nil}, _now), do: false
  defp wanted?(%{wanted_until: until}, now), do: DateTime.compare(until, now) == :gt

  defp heartbeat_expired?(%{last_worker_heartbeat_at: nil}, _now), do: true

  defp heartbeat_expired?(%{last_worker_heartbeat_at: at}, now),
    do: DateTime.diff(now, at, :microsecond) >= 60_000_000

  defp sweep_objects(provider) do
    {:ok, kind} = ProviderKind.fetch(provider.kind)

    case kind.list_instances(provider, :all) do
      {:ok, objects} ->
        rows =
          provider.provider_id
          |> AgentWorkers.provider_workers()
          |> Map.new(&{{&1.tenant_id, &1.agent_uid}, &1})

        now = Repo.now!()

        Enum.each(objects, fn object ->
          case rows[{object.tenant_id, object.agent_uid}] do
            nil ->
              delete_orphan(provider, kind, object)

            row ->
              lifetime = ProviderKind.instance_lifetime(kind, row.instance_settings)

              if object.generation != row.generation or phase_differs?(row, object) or
                   Decision.lifetime_due?(object.started_at, lifetime, now),
                 do: ReconcileJob.enqueue(row)
          end
        end)

        present = MapSet.new(objects, &{&1.tenant_id, &1.agent_uid, &1.generation})

        # Reuse the inventory read above. ReconcileJob checks the current row
        # again before it changes a Worker.
        Enum.each(rows, fn {_uid, row} ->
          if missing_instance?(row, present, now), do: ReconcileJob.enqueue(row)
        end)

      {:error, reason} ->
        log_failure("object_sweep", provider, reason)
    end
  end

  defp missing_instance?(row, present, now) do
    eligible =
      row.state in [:ready, :stale, :paused] or
        (row.state == :starting and DateTime.diff(now, row.state_changed_at) > 60)

    eligible and not MapSet.member?(present, {row.tenant_id, row.agent_uid, row.generation})
  end

  # The platform changed the instance outside the control plane, for example
  # an operator resumed a paused instance or the process ended.
  defp phase_differs?(row, object),
    do: object.phase == :exited or row.state == :paused != (object.phase == :paused)

  # Check durable ownership again before deleting a platform orphan.
  # The platform call runs outside any transaction.
  defp delete_orphan(provider, kind, object) do
    owner =
      object.agent_uid &&
        provider.provider_id
        |> AgentWorkers.provider_workers()
        |> Enum.find(&(&1.tenant_id == object.tenant_id and &1.agent_uid == object.agent_uid))

    result =
      if owner,
        do: ReconcileJob.enqueue(owner),
        else: kind.delete_instance(provider, object, :now)

    if match?({:error, _}, result), do: log_failure("orphan_delete", provider, result)
  end

  defp log_failure(operation, provider, reason) do
    Logging.warning("agent_workers.#{operation}_failed", "Worker provider sweep failed", %{
      provider_id: provider.provider_id,
      reason: inspect(reason)
    })
  end
end
