defmodule Ankole.OIDC.Jobs.CleanupExpiredCredentials do
  @moduledoc """
  Idempotent hourly cleanup for expired authorization codes and refresh tokens.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.OIDC

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{} = job) do
    metadata = %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      counts = OIDC.cleanup_expired_credentials()
      {:ok, counts |> Map.merge(metadata) |> Map.put(:result, :ok)}
    end)
  end
end
