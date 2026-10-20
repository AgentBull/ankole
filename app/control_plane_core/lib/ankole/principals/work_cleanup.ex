defmodule Ankole.Principals.WorkCleanup do
  @moduledoc "Durable cleanup of future work after Human access revocation."
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query
  alias Ankole.Principals.AccessEvent
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  def enqueue_in_tx(uid, version) do
    with {:ok, _} <- Oban.insert(new(%{"human_uid" => uid, "version" => version})), do: :ok
  end

  # The audit row commits with the stop mutations. Tenant teardown can process
  # a bounded batch without inventing a second cleanup checkpoint.
  def pending_for_tenant(limit) do
    Repo.all(
      from principal in Principal,
        as: :human,
        where: principal.type == :human and principal.status == :disabled,
        where:
          not exists(
            from event in AccessEvent,
              where:
                event.principal_uid == parent_as(:human).uid and event.source == "work_cleanup" and
                  event.operation_id ==
                    fragment("'access-version:' || ?::text", parent_as(:human).access_version),
              select: 1
          ),
        order_by: principal.uid,
        limit: ^limit
    )
  end

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"human_uid" => uid, "version" => version}}) do
    if Ankole.AuthZ.administrator_recovery_required?() do
      Ankole.Logging.warning(
        "principals.admin_recovery_required",
        "No active Human administrator remains; use the audited ankole.admin.recover operator command",
        %{principal_uid: uid}
      )
    end

    case cleanup(uid, version) do
      {:ok, %{running: 0}} ->
        :ok

      {:ok, _} ->
        {:snooze, 60}

      {:error, reason} ->
        Ankole.Logging.warning(
          "principals.work_cleanup.failed",
          "Future work cleanup failed; retry the stored cleanup job",
          %{principal_uid: uid, access_version: version}
        )

        {:error, reason}
    end
  end

  def cleanup(uid, version) do
    Repo.transact(fn repo ->
      principal = repo.one!(from p in Principal, where: p.uid == ^uid, lock: "FOR UPDATE")
      now = DateTime.utc_now()

      results =
        Repo.across_tenants(fn ->
          [
            {"cron", Ankole.Schedule.Cron.stop_human_work_in_tx(repo, uid, version, now)},
            {"scheduled_events",
             Ankole.Schedule.Checkbacks.stop_human_work_in_tx(repo, uid, version, now)},
            {"background_jobs",
             Ankole.BackgroundAgentJobs.Lifecycle.stop_human_work_in_tx(repo, uid, version, now)},
            {"workflow_calls", Ankole.Workflow.stop_human_work_in_tx(repo, uid, version, now)},
            {"automation_runs",
             Ankole.AutomationJobs.stop_human_work_in_tx(repo, uid, version, now)},
            {"signals", Ankole.Sessions.Queue.stop_human_work_in_tx(repo, uid, version, now)}
          ]
          |> Map.new(fn {kind, {count, _}} -> {kind, count} end)
        end)

      running = Repo.across_tenants(fn -> running_count(repo, uid, version) end)

      repo.insert!(
        Ecto.Changeset.change(%AccessEvent{}, %{
          principal_uid: uid,
          operation_id: "access-version:#{version}",
          source: "work_cleanup",
          action: "stop_future_work",
          reason: "human_access_revoked",
          previous_status: principal.status,
          status: principal.status,
          access_version: version,
          details: Map.put(results, "admitted_attempts_allowed_to_finish", running)
        }),
        on_conflict: :nothing,
        conflict_target: [:source, :operation_id, :principal_uid]
      )

      {:ok, %{running: running, stopped: results}}
    end)
  end

  defp running_count(repo, uid, version) do
    events =
      from e in Ankole.Signals.Signal,
        where:
          e.human_uid == ^uid and e.human_access_version < ^version and is_nil(e.completed_at),
        select: e.id

    deliveries =
      repo.aggregate(
        from(e in Ankole.Signals.Signal,
          where:
            e.id in subquery(events) and not is_nil(e.last_attempt_at) and is_nil(e.completed_at) and
              e.input_state == "open"
        ),
        :count
      )

    jobs =
      from j in Ankole.AutomationJobs.Schemas.Job,
        where: j.human_uid == ^uid and j.human_access_version < ^version,
        select: j.id

    deliveries +
      repo.aggregate(
        from(r in Ankole.AutomationJobs.Schemas.Run,
          where: r.automation_job_id in subquery(jobs) and r.status == "running"
        ),
        :count
      )
  end
end
