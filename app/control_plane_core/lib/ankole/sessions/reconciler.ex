defmodule Ankole.Sessions.Reconciler do
  @moduledoc "Repairs lost wakeups from durable input, Workflow, and intent state."
  use Ankole.Job, tenancy: :site, queue: :conversations, max_attempts: 3
  alias Ankole.Repo
  alias Ankole.Sessions.Jobs.EnsureDriver

  @impl true
  # Recovery includes suspended tenants: admission stops new work, while already
  # admitted runs still need their committed wakeups after an instance disappears.
  def run(_job), do: reconcile()

  def reconcile(now \\ DateTime.utc_now(:microsecond)) do
    results = [
      reconcile_inputs(now),
      Ankole.Workflow.reconcile_run_wakeups(),
      Ankole.Conversations.Delivery.reconcile_wakeups(now)
    ]

    Enum.find(results, :ok, &(&1 != :ok))
  end

  defp reconcile_inputs(now) do
    keys = Ankole.Signals.due_sessions_across_tenants(now)

    Enum.reduce(keys, :ok, fn key, previous ->
      result =
        Repo.with_tenant(key.tenant_id, fn ->
          case Ankole.Sessions.driver_pid(key) do
            :undefined ->
              EnsureDriver.enqueue(key, now)

            pid ->
              send(pid, :reconcile_inbox)
              :ok
          end
        end)

      case result do
        :ok ->
          previous

        {:ok, _job} ->
          previous

        {:error, reason} = error ->
          Ankole.Logging.warning(
            "sessions.reconciliation_failed",
            "Session reconciliation failed",
            Map.merge(Ankole.Logging.failure_fields(:error, reason, []), key)
          )

          error
      end
    end)
  end
end
