defmodule Ankole.IdentityProviders.Jobs.ProcessDirectoryEvent do
  @moduledoc false
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:event_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"event_id" => id}}),
    do: Ankole.IdentityProviders.DirectoryAccess.process_event(id)
end
