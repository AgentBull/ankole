defmodule Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs do
  @moduledoc """
  Periodic enqueue edge for identity-provider full directory syncs.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.IdentityProviders.DirectorySync

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, map()} | {:error, term()}
  def perform(%Oban.Job{} = job) do
    metadata = job_metadata(job)

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      result = DirectorySync.enqueue_directory_syncs(reason: "periodic", source: "cron")
      {result, Map.put(metadata, :result, result_status(result))}
    end)
  end

  defp job_metadata(%Oban.Job{} = job) do
    %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}
  end

  defp result_status({:ok, _result}), do: :ok
  defp result_status({:error, _reason}), do: :error
end
