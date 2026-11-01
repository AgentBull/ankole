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
  require Ash.Query
  alias Ankole.Principals.AccessEvent
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  def enqueue_in_tx(uid, version) do
    with {:ok, _} <- Oban.insert(new(%{"human_uid" => uid, "version" => version})), do: :ok
  end

  def jobs_for_human(uid) do
    tenant_id = Repo.tenant_id!()

    Repo.all(
      from job in Oban.Job,
        where:
          fragment("?->>'tenant_id' = ?", job.args, ^tenant_id) and
            job.worker == "Ankole.Principals.WorkCleanup" and
            fragment("?->>'human_uid' = ?", job.args, ^uid),
        order_by: [desc: job.id],
        limit: 20
    )
  end

  # The audit row commits with the stop mutations. Tenant teardown can process
  # a bounded batch without inventing a second cleanup checkpoint.
  def pending_for_tenant(limit) do
    Principal
    |> Ash.Query.filter(
      type == :human and status == :disabled and
        not exists(
          access_events,
          source == "work_cleanup" and
            operation_id == fragment("'access-version:' || ?::text", parent(access_version))
        )
    )
    |> Ash.Query.sort(uid: :asc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read!()
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

  def cleanup(uid, version),
    do: Repo.transact_top_level(fn -> cleanup_in_tx(uid, version) end)

  @doc false
  def cleanup_in_tx(uid, version) do
    with {:ok, principal} <- Ankole.Principals.lock_principal_in_tx(uid) do
      now = DateTime.utc_now()

      results = Ankole.Work.Owner.revoke_human_work_in_tx(uid, version, now)

      running =
        Ankole.Signals.count_admitted_attempts_for_human(uid, version) +
          Ankole.AutomationJobs.count_running_runs_for_human(uid, version)

      with {:ok, _event} <-
             Ankole.Ash.create(AccessEvent, :record_once_in_tx, %{
               principal_uid: uid,
               operation_id: "access-version:#{version}",
               source: "work_cleanup",
               action: "stop_future_work",
               reason: "human_access_revoked",
               previous_status: principal.status,
               status: principal.status,
               access_version: version,
               details: Map.put(results, "admitted_attempts_allowed_to_finish", running)
             }) do
        {:ok, %{running: running, stopped: results}}
      end
    end
  end
end
