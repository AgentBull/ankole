defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.SweepJob do
  @moduledoc """
  Finds pending Worker work and provider-scoped orphan instances.

  Each provider is loaded independently. A bad configuration must not stop
  other providers. An unobserved starting generation is retried, never
  declared absent by a sweep. Only reconciliation can settle a generation.
  """

  use Ankole.Job, tenancy: :site, queue: :agent_workers, max_attempts: 1
  import Ecto.Query
  alias Ankole.{Logging, Repo}
  alias Ankole.Principals.Principal

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.{
    Decision,
    ProviderKind,
    PrepareImageJob,
    Providers,
    ReconcileJob
  }

  alias Ankole.SignalsGateway.ActorRuntime.AgentWorkers.Providers.Configuration
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker

  @impl true
  def run(job), do: sweep(job)

  defp sweep(%Oban.Job{args: args}) do
    rows(
      from w in AgentWorker,
        where: w.state == "deleting" and is_nil(w.provider_id),
        select: w
    )
    |> Enum.each(&ReconcileJob.enqueue/1)

    Enum.each(Providers.list(), fn row ->
      case Providers.load(row) do
        {:ok, provider} ->
          PrepareImageJob.enqueue(provider)
          candidates(provider) |> Enum.each(&ReconcileJob.enqueue/1)
          if Map.get(args, "objects"), do: sweep_objects(provider)

        {:error, _reason} ->
          # Reconciliation writes this provider's failure to each affected row.
          rows(from w in AgentWorker, where: w.provider_id == ^row.provider_id, select: w)
          |> Enum.each(&ReconcileJob.enqueue/1)
      end
    end)

    :ok
  end

  # Only the inventory read crosses tenants. Enqueueing binds each selected
  # row's tenant, and provider I/O runs with no query bypass in force.
  defp rows(query), do: Repo.across_tenants(fn -> Repo.all(query) end)

  defp candidates(provider) do
    idle =
      case Configuration.duration_ms(provider.settings["idleReleaseAfter"]) do
        :never ->
          dynamic(false)

        ms ->
          dynamic(
            [w],
            fragment("coalesce((?->>'active_tasks')::bigint, -1) = 0", w.load) and
              fragment("coalesce((?->>'idle_for_ms')::bigint, 0) >= ?", w.load, ^ms)
          )
      end

    turn =
      dynamic(
        [w],
        fragment(
          "EXISTS (SELECT 1 FROM background_agent_jobs j WHERE j.agent_uid = ? AND j.status = 'running') OR coalesce((?->>'active_slots')::bigint, 0) > 0",
          w.agent_uid,
          w.load
        )
      )

    conditions =
      dynamic(
        [w, p],
        w.state in ["starting", "stale", "draining", "deleting"] or
          (not is_nil(w.generation) and
             (w.image != ^provider.runtime.image or
                w.protocol_version != ^provider.runtime.protocol_version or
                w.settings_digest != ^provider.settings_digest)) or
          (w.state in ["absent", "paused"] and p.status == :active and
             (w.wanted_until > fragment("now()") or ^turn)) or
          (w.state == "ready" and (is_nil(p.uid) or p.status != :active or ^idle))
      )

    rows(
      from w in AgentWorker,
        left_join: p in Principal,
        on: p.uid == w.agent_uid,
        where: w.provider_id == ^provider.provider_id,
        where: ^conditions,
        select: w
    )
  end

  defp sweep_objects(provider) do
    {:ok, kind} = ProviderKind.fetch(provider.kind)

    case kind.list_instances(provider, :all) do
      {:ok, objects} ->
        rows =
          rows(from w in AgentWorker, where: w.provider_id == ^provider.provider_id)
          |> Map.new(&{&1.agent_uid, &1})

        %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

        Enum.each(objects, fn object ->
          case rows[object.agent_uid] do
            nil ->
              delete_orphan(provider, kind, object)

            row ->
              lifetime = ProviderKind.instance_lifetime(kind, row.instance_settings)

              if object.generation != row.generation or phase_differs?(row, object) or
                   Decision.lifetime_due?(object.started_at, lifetime, now),
                 do: ReconcileJob.enqueue(row)
          end
        end)

        present = MapSet.new(objects, &{&1.agent_uid, &1.generation})

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
      row.state in ["ready", "stale", "paused"] or
        (row.state == "starting" and DateTime.diff(now, row.state_changed_at) > 60)

    eligible and not MapSet.member?(present, {row.agent_uid, row.generation})
  end

  # The platform changed the instance outside the control plane, for example
  # an operator resumed a paused instance or the process ended.
  defp phase_differs?(row, object),
    do: object.phase == :exited or row.state == "paused" != (object.phase == :paused)

  # Check durable ownership again before deleting a platform orphan.
  # The platform call runs outside any transaction.
  defp delete_orphan(provider, kind, object) do
    owner =
      object.agent_uid &&
        from(w in AgentWorker,
          where: w.agent_uid == ^object.agent_uid and w.provider_id == ^provider.provider_id,
          select: w
        )
        |> rows()
        |> List.first()

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
