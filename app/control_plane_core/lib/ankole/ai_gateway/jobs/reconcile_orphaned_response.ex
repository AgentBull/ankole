defmodule Ankole.AIGateway.Jobs.ReconcileOrphanedResponse do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :conversations,
    max_attempts: 5,
    unique: [keys: [:message_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  def schedule_in_tx(repo, args, due_at),
    do: Ankole.Job.schedule_in_tx(repo, __MODULE__, args, due_at)

  @impl true
  def run(%Oban.Job{args: args}),
    do: Ankole.AIGateway.reconcile_orphaned_response(args["message_id"])
end
