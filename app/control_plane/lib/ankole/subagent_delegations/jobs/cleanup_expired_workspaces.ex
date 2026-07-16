defmodule Ankole.SubagentDelegations.Jobs.CleanupExpiredWorkspaces do
  @moduledoc """
  Bounded recurring cleanup for managed Deep Research workspaces.

  Forecast dossiers and normalized runtime Turn trajectories belong to the
  delegation and are intentionally outside this cleanup surface.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.SubagentDelegations

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{} = job) do
    metadata = %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      _counts = SubagentDelegations.cleanup_expired_workspaces()
      {:ok, Map.put(metadata, :result, :ok)}
    end)
  end
end
