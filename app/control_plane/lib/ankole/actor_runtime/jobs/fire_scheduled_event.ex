defmodule Ankole.ActorRuntime.Jobs.FireScheduledEvent do
  @moduledoc """
  Oban wake edge for one scheduled actor event.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [
      fields: [:worker, :args],
      keys: [:scheduled_event_id],
      states: :incomplete
    ]

  alias Ankole.ActorRuntime.ActivationManager
  alias Ankole.Schedule

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:cancel, term()} | {:error, term()}
  def perform(%Oban.Job{} = job) do
    metadata = job_metadata(job)

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      result = do_perform(job)
      {result, Map.put(metadata, :result, result_status(result))}
    end)
  end

  defp do_perform(%Oban.Job{args: %{"scheduled_event_id" => scheduled_event_id}})
       when is_binary(scheduled_event_id) do
    case Schedule.fire_due_event(scheduled_event_id) do
      {:ok, %{status: :fired}} ->
        ActivationManager.wake()
        :ok

      {:ok, %{status: :noop}} ->
        :ok

      {:ok, %{status: :cancelled}} ->
        :ok

      {:error, {:permanent, reason}} ->
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_perform(%Oban.Job{}), do: {:cancel, :missing_scheduled_event_id}

  defp job_metadata(%Oban.Job{} = job) do
    %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}
  end

  defp result_status(:ok), do: :ok
  defp result_status({:cancel, _reason}), do: :cancel
  defp result_status({:error, _reason}), do: :error
end
