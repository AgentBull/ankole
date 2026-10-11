defmodule Ankole.Conversations.Reconciler do
  @moduledoc "Repairs lost wakeups from durable input, Workflow, and outbox state."
  use Ankole.Job, tenancy: :site, queue: :conversations, max_attempts: 3
  require Logger
  import Ecto.Query
  alias Ankole.Repo
  alias Ankole.Conversations.{Driver, Jobs.EnsureDriver}
  alias Ankole.SignalsGateway.ActorEvent

  @impl true
  # Recovery includes suspended tenants: admission stops new work, while already
  # admitted runs still need their committed wakeups after an instance disappears.
  def run(_job), do: reconcile()

  def reconcile(now \\ DateTime.utc_now(:microsecond)) do
    results = [
      reconcile_inputs(now),
      Ankole.Workflow.reconcile_run_wakeups(),
      Ankole.SignalsGateway.Outbox.reconcile_wakeups(now)
    ]

    Enum.find(results, :ok, &(&1 != :ok))
  end

  defp reconcile_inputs(now) do
    keys =
      Repo.across_tenants(fn ->
        Repo.all(
          from e in ActorEvent,
            where: e.input_state == "open" and is_nil(e.completed_at) and e.available_at <= ^now,
            distinct: [e.agent_uid, e.session_id],
            select: %{agent_uid: e.agent_uid, session_id: e.session_id, tenant_id: e.tenant_id}
        )
      end)

    Enum.reduce(keys, :ok, fn key, previous ->
      result =
        Repo.with_tenant(key.tenant_id, fn ->
          case Driver.whereis(key) do
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
          Logger.warning(
            "Conversation reconciliation failed for #{inspect(key)}: #{inspect(reason)}"
          )

          error
      end
    end)
  end
end
