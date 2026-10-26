defmodule Ankole.OIDC.LogoutWorker do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 30,
    unique: [
      period: :infinity,
      keys: [:delivery_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"delivery_id" => id}}), do: Ankole.OIDC.Logout.deliver(id)
end
