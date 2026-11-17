defmodule Ankole.Plugins.Jobs.PeriodicChannelSync do
  @moduledoc "Periodically refreshes IM group projections so missed webhook deltas self-heal."
  use Ankole.Job,
    tenancy: :site,
    queue: :conversations,
    max_attempts: 3,
    unique: [
      fields: [:worker],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Ankole.Job
  def run(_job) do
    Ankole.Plugins.ChannelSync.enqueue_periodic_all()
    :ok
  end
end
