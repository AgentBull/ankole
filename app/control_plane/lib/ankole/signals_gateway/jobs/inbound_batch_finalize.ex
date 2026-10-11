defmodule Ankole.SignalsGateway.Jobs.InboundBatchFinalize do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :conversations,
    max_attempts: 5,
    unique: [keys: [:batch_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  def schedule_in_tx(repo, args, due_at),
    do: Ankole.Job.schedule_in_tx(repo, __MODULE__, args, due_at)

  # One wakeup serves every revision of a batch. A wakeup that runs before the
  # batch is due, for example on a node with an earlier clock, waits again.
  @impl true
  def run(%Oban.Job{args: args}) do
    case Ankole.SignalsGateway.finalize_inbound_batch_by_id(args["batch_id"]) do
      {:ok, %{status: :not_due, available_at: due_at}} ->
        {:snooze, max(DateTime.diff(due_at, DateTime.utc_now(), :second), 1)}

      {:ok, _} ->
        :ok

      {:error, :inbound_batch_not_found} ->
        :ok

      error ->
        error
    end
  end
end
