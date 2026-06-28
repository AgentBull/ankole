defmodule Ankole.SignalsGateway.Jobs.CleanupExpiredState do
  @moduledoc """
  Bounded recurring cleanup for SignalsGateway TTL state.

  The gateway writes tombstones with a 24h expiry but never deletes them inline
  (ingress should stay a thin write path). This Oban worker is the sweeper that
  reclaims expired rows so the tombstone table self-empties. It is purely
  housekeeping: dropping an already-expired tombstone changes no behavior, which
  is why a missed or retried run is harmless.
  """

  # max_attempts: 3 because the body is idempotent and best-effort — if a sweep
  # fails it will simply run again on the next schedule; there is nothing to
  # carefully preserve across retries.
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.SignalsGateway

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{} = job) do
    metadata = job_metadata(job)

    :telemetry.span([:ankole, :oban, :job], metadata, fn ->
      result = do_perform()
      {result, Map.put(metadata, :result, result_status(result))}
    end)
  end

  defp do_perform do
    # Counts are intentionally discarded; the job is for the side effect, and
    # always reports :ok so Oban does not retry successful housekeeping.
    _counts = SignalsGateway.cleanup_expired_state()
    :ok
  end

  defp job_metadata(%Oban.Job{} = job) do
    %{worker: __MODULE__, queue: job.queue, job_id: job.id, attempt: job.attempt}
  end

  defp result_status(:ok), do: :ok
end
