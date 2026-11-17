defmodule Ankole.Connectors.Jobs.ReconcileTriggers do
  @moduledoc false
  use Ankole.Job,
    tenancy: :site,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :retryable]
    ]

  require Ash.Query
  @healthy_verify_interval_seconds 45 * 60

  @impl Ankole.Job
  def run(_job) do
    cutoff =
      DateTime.add(DateTime.utc_now(:microsecond), -@healthy_verify_interval_seconds, :second)

    Ankole.Connectors.Trigger
    |> Ash.Query.for_read(:across_tenants)
    |> Ash.Query.filter(
      status != "degraded" and
        (status != "active" or is_nil(last_verified_at) or last_verified_at <= ^cutoff)
    )
    |> Ankole.Ash.read_across_tenants!()
    |> Enum.each(fn trigger ->
      Ankole.Repo.with_tenant(trigger.tenant_id, fn ->
        Oban.insert(Ankole.Connectors.Jobs.ReconcileTrigger.new(%{"trigger_id" => trigger.id}))
      end)
    end)

    :ok
  end
end
