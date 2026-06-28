defmodule Ankole.ActorRuntime.Jobs.EnqueueDailySessionResets do
  @moduledoc """
  Control-plane cron job that appends due `session.reset_due` actor inputs.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  alias Ankole.ActorRuntime

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{} = job) do
    metadata = job_metadata(job)

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      result = do_perform()
      {result, Map.put(metadata, :result, result_status(result))}
    end)
  end

  defp do_perform do
    case ActorRuntime.enqueue_daily_session_resets() do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp job_metadata(%Oban.Job{} = job) do
    %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}
  end

  defp result_status(:ok), do: :ok
  defp result_status({:error, _reason}), do: :error
end
