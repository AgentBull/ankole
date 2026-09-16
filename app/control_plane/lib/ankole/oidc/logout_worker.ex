defmodule Ankole.OIDC.LogoutWorker do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 30,
    unique: [
      period: :infinity,
      keys: [:delivery_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}}), do: Ankole.OIDC.Logout.deliver(id)
end
