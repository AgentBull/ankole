defmodule Ankole.IdentityProviders.Jobs.SyncProvider do
  @moduledoc """
  Durable full-directory sync for identity-provider adapters.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.IdentityProviders

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: {:ok, term()} | {:error, term()}
  def perform(%Oban.Job{} = job) do
    metadata = job_metadata(job)

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      result = do_perform(job)
      {result, Map.put(metadata, :result, result_status(result))}
    end)
  end

  defp do_perform(%Oban.Job{args: %{"provider_id" => provider_id}}) when is_binary(provider_id) do
    IdentityProviders.sync_provider(provider_id)
  end

  defp job_metadata(%Oban.Job{} = job) do
    %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}
  end

  defp result_status({:ok, _result}), do: :ok
  defp result_status({:error, _reason}), do: :error
end
