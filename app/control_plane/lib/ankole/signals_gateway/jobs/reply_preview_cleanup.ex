defmodule Ankole.SignalsGateway.Jobs.ReplyPreviewCleanup do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :outbox,
    max_attempts: 5,
    unique: [
      keys: [:actor_event_id],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ]

  def schedule_in_tx(repo, args, due_at),
    do: Ankole.Job.schedule_in_tx(repo, __MODULE__, args, due_at)

  @impl true
  def run(%Oban.Job{args: args}) do
    case Ankole.SignalsGateway.cleanup_reply_preview(args["actor_event_id"]) do
      :ok ->
        :ok

      {:error, reason}
      when reason in [
             :reply_preview_cleanup_not_due,
             :reply_preview_not_recoverable,
             :actor_event_not_found
           ] ->
        :ok

      error ->
        error
    end
  end
end
