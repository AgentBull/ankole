defmodule Ankole.Schedule.Jobs.FireCron do
  @moduledoc false

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 10,
    unique: [
      fields: [:worker, :args],
      keys: [:cron_schedule_id],
      states: [:available, :scheduled, :retryable]
    ]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"cron_schedule_id" => id}} = job) do
    case Ankole.Schedule.fire_cron(id, attempt: job.attempt, max_attempts: job.max_attempts) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
