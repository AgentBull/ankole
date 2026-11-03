defmodule Ankole.Pod.Jobs.DeliverBaseChanges do
  @moduledoc "Drains committed Base outboxes; duplicate delivery is deduplicated by Binding receipts."
  use Ankole.Job,
    tenancy: :site,
    queue: :outbox,
    max_attempts: 5,
    unique: [
      fields: [:worker, :args],
      keys: [:tenant_id],
      states: [:available, :scheduled, :retryable]
    ]

  @impl Ankole.Job
  def run(%{args: %{"tenant_id" => tenant}}) do
    Ankole.Repo.with_tenant(tenant, fn ->
      if Ankole.Tenants.accepting_work?(tenant), do: Ankole.Pod.Bases.Outbox.drain(), else: :ok
    end)
  end

  def run(_job) do
    (&Ankole.Pod.Bases.Outbox.wake/0)
    |> Ankole.Tenants.map_active()
    |> Ankole.Tenants.fanout_result()
  end
end
