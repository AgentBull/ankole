defmodule Ankole.AIGateway.Jobs.RunMediaJob do
  @moduledoc """
  Runs one video or music generation to its end. The job snoozes while the
  Provider works, which does not count as an attempt.
  """
  use Ankole.Job,
    tenancy: :tenant,
    queue: :media_jobs,
    max_attempts: 5,
    unique: [
      period: 300,
      fields: [:worker, :args],
      keys: [:media_job_id],
      states: [:available, :scheduled, :retryable]
    ]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"media_job_id" => id}, attempt: attempt, max_attempts: max_attempts}) do
    last_attempt? = attempt >= max_attempts

    try do
      Ankole.AIGateway.MediaJobs.run(id, last_attempt?)
    rescue
      exception ->
        if last_attempt?, do: Ankole.AIGateway.MediaJobs.fail_unexpected(id, exception)
        reraise exception, __STACKTRACE__
    end
  end
end
