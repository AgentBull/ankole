defmodule Ankole.Files.Jobs.CollectUnreferenced do
  @moduledoc "Collects tenant objects without references after their upload grace period."
  use Ankole.Job,
    tenancy: :site,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: Oban.Job.states() -- [:completed, :cancelled, :discarded]]

  alias Ankole.{Files, Logging, Repo, Tenants}

  @impl Ankole.Job
  def run(%Oban.Job{}) do
    Enum.each(Tenants.list_tenants!(), fn tenant ->
      case Repo.with_tenant(tenant.id, &Files.collect_objects/0) do
        {:ok, 0} ->
          :ok

        {:ok, removed} ->
          Logging.info("files.collect_unreferenced", "collected unreferenced objects", %{
            tenant_id: tenant.id,
            removed: removed
          })

        {:error, reason} ->
          Logging.warning("files.collect_unreferenced_failed", "object collection failed", %{
            tenant_id: tenant.id,
            reason: inspect(reason)
          })
      end
    end)

    :ok
  end
end
