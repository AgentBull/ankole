defmodule Ankole.IdentityProviders.Jobs.ProcessDirectoryEvent do
  @moduledoc false
  use Oban.Worker,
    queue: :default,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:event_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"event_id" => id}}),
    do: Ankole.IdentityProviders.DirectoryAccess.process_event(id)
end
