defmodule Ankole.SignalsGateway.Jobs.OutboxDispatch do
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

  def schedule_in_tx(_repo, args, nil) do
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

  def schedule_in_tx(repo, args, due_at),
    do: Ankole.Job.schedule_in_tx(repo, __MODULE__, args, due_at)

  @impl true
  def run(%Oban.Job{args: args}) do
    case Ankole.SignalsGateway.dispatch_outbox_by_key(
           args["agent_uid"],
           args["binding_name"],
           args["outbound_key"]
         ) do
      {:ok, _} ->
        :ok

      {:error, reason}
      when reason in [
             :outbox_not_dispatchable,
             :attachment_migration_required,
             :outbox_not_due,
             :outbox_send_in_progress,
             :outbox_operator_action_required,
             :outbox_attempts_exhausted,
             :outbox_manual_requeue_required,
             :outbox_not_found
           ] ->
        :ok

      error ->
        error
    end
  end
end
