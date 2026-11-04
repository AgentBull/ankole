defmodule Ankole.Connectors.Jobs.ReconcileTrigger do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [period: 30, fields: [:args], states: [:available, :scheduled, :retryable]]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"trigger_id" => id}}) do
    case Ankole.Connectors.Triggers.reconcile(id) do
      {:ok, _} ->
        :ok

      {:error, reason}
      when reason in [:connector_trigger_busy, :connector_trigger_degraded, :not_found] ->
        :ok

      {:error, %{code: code}}
      when code in ["connector_trigger_busy", "connector_refresh_in_progress"] ->
        {:snooze, 2}

      error ->
        error
    end
  end
end
