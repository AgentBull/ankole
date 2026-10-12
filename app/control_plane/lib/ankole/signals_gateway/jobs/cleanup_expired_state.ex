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
  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  alias Ankole.SignalsGateway

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: :ok
  def run(_job), do: Ankole.Tenants.map_all(&do_perform/0) |> Ankole.Tenants.fanout_result()

  defp do_perform do
    # Counts are intentionally discarded; the job is for the side effect, and
    # always reports :ok so Oban does not retry successful housekeeping.
    _counts = SignalsGateway.cleanup_expired_state()
    :ok
  end
end
