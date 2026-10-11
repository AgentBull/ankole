defmodule Ankole.OIDC.Jobs.CleanupExpiredCredentials do
  @moduledoc """
  Hourly cleanup for expired credentials, browser transactions, and unused session state.
  """

  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3

  alias Ankole.OIDC

  @impl Ankole.Job
  @spec perform(Oban.Job.t()) :: :ok
  def run(job), do: Ankole.Repo.across_tenants(fn -> sweep(job) end)

  defp sweep(%Oban.Job{}) do
    _counts = OIDC.cleanup_expired_credentials()
    :ok
  end
end
