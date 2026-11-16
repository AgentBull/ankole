defmodule Ankole.Signals.Jobs.CleanupExpiredState do
  @moduledoc """
  Bounded recurring cleanup for Signals TTL state.

  The gateway writes tombstones with a 24h expiry but never deletes them inline
  (ingress should stay a thin write path). This Oban worker is the sweeper that
  reclaims expired rows so the tombstone table self-empties. It is purely
  housekeeping: dropping an already-expired tombstone changes no behavior, which
  is why a missed or retried run is harmless.
  """

  # The sweep is idempotent housekeeping, and the next scheduled run reclaims
  # any expired rows left behind by a transient failure.
  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: :ok
  def run(_job), do: Ankole.Tenants.map_all(&do_perform/0) |> Ankole.Tenants.fanout_result()

  defp do_perform do
    # Counts are intentionally discarded; the job is for the side effect, and
    # always reports :ok so Oban does not retry successful housekeeping.
    _counts = Ankole.Signals.StateCleanup.cleanup_expired_state()
    :ok
  end
end
