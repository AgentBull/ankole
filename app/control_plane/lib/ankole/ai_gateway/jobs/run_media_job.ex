defmodule Ankole.AIGateway.Jobs.RunMediaJob do
  @moduledoc """
  Runs one video or music generation to its end. The job snoozes while the
  Provider works, which does not count as an attempt.
  """
  use Ankole.Job, tenancy: :tenant, queue: :default, max_attempts: 5

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"media_job_id" => id}, attempt: attempt, max_attempts: max_attempts}),
    do: Ankole.AIGateway.MediaJobs.run(id, attempt >= max_attempts)
end
