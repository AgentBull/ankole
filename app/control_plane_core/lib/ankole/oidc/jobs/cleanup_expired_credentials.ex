defmodule Ankole.OIDC.Jobs.CleanupExpiredCredentials do
  @moduledoc """
  Hourly cleanup for expired credentials, browser transactions, and unused session state.
  """

  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  alias Ankole.{BrowserSessions, OIDC, Tenants}

  @impl Ankole.Job
  @spec run(Oban.Job.t()) :: :ok | {:error, term()}
  def run(%Oban.Job{}) do
    now = DateTime.utc_now(:microsecond)
    results = Tenants.map_all(fn -> sweep(now) end)
    BrowserSessions.cleanup_expired(now)
    Tenants.fanout_result(results)
  end

  defp sweep(now) do
    _counts = OIDC.cleanup_expired_credentials(now)
    :ok
  end
end
