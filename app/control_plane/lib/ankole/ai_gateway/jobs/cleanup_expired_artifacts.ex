defmodule Ankole.AIGateway.Jobs.CleanupExpiredArtifacts do
  @moduledoc """
  Idempotent hourly cleanup for expired artifacts and failed generated images.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.AIGateway.Artifacts

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{} = job) do
    metadata = %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      count = Artifacts.cleanup_expired_and_failed()
      {:ok, Map.merge(metadata, %{result: :ok, deleted_count: count})}
    end)
  end
end
