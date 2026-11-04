defmodule Ankole.Connectors.Jobs.ReconcileTriggers do
  @moduledoc false
  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3
  require Ash.Query
  @impl Ankole.Job
  def run(_job) do
    Ankole.Connectors.Trigger
    |> Ash.Query.for_read(:across_tenants)
    |> Ash.Query.filter(status != "degraded")
    |> Ankole.Ash.read_across_tenants!()
    |> Enum.each(fn trigger ->
      Ankole.Repo.with_tenant(trigger.tenant_id, fn ->
        Oban.insert(Ankole.Connectors.Jobs.ReconcileTrigger.new(%{"trigger_id" => trigger.id}))
      end)
    end)

    :ok
  end
end
