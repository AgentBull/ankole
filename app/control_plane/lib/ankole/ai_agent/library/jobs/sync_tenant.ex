defmodule Ankole.AIAgent.Library.Jobs.SyncTenant do
  @moduledoc """
  Installs the shipped Skill packages and organization templates of a new tenant.

  `StartupSync` covers the tenants that exist when the control plane starts. A
  tenant created later gets this job, so its first Agent Library read does not
  copy every shipped Skill file inside the request.
  """
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable]]

  alias Ankole.AIAgent.Library

  @impl Ankole.Job
  def run(%Oban.Job{}) do
    with {:ok, sources} <- Library.shipped_skill_sources(),
         {:ok, _} <- Library.StartupSync.sync_tenant(sources),
         do: :ok
  end
end
