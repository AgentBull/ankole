defmodule Ankole.Conversations.Delivery.Jobs.Dispatch do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :outbox,
    max_attempts: 5,
    unique: [
      keys: [:agent_uid, :binding_name, :outbound_key],
      period: :infinity,
      states: [:available, :scheduled, :retryable]
    ]

  import Ecto.Query

  def schedule_in_tx(args, nil) do
    {:ok, _} =
      Oban.cancel_all_jobs(
        from job in Oban.Job,
          where:
            job.worker == ^Oban.Worker.to_string(__MODULE__) and
              job.state in ["available", "scheduled", "retryable"],
          where: fragment("? @> ?", job.args, ^args)
      )

    :ok
  end

  def schedule_in_tx(args, due_at),
    do: Ankole.Job.schedule_in_tx(__MODULE__, args, due_at)

  @impl true
  def run(%Oban.Job{args: args}) do
    case Ankole.Conversations.Delivery.dispatch_by_key(
           args["agent_uid"],
           args["binding_name"],
           args["outbound_key"]
         ) do
      {:ok, _} ->
        :ok

      {:error, :reply_preview_settle_timeout} ->
        {:snooze, 1}

      {:error, {:reply_presentation_not_terminal, _state} = reason} ->
        {:cancel, reason}

      {:error, reason}
      when reason in [
             :intent_not_dispatchable,
             :attachment_migration_required,
             :intent_not_due,
             :intent_send_in_progress,
             :intent_operator_action_required,
             :intent_attempts_exhausted,
             :intent_manual_requeue_required,
             :intent_not_found
           ] ->
        :ok

      error ->
        error
    end
  end
end
