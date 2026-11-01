defmodule Ankole.Plugins.Microsoft365Adapter.Jobs.SyncChannels do
  @moduledoc false

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [fields: [:worker, :args], keys: [:binding_id], period: 300]

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"binding_id" => binding_id}}),
    do: Ankole.Plugins.Microsoft365Adapter.TeamsChannels.sync_binding(binding_id)

  def run(%Oban.Job{}), do: {:error, :missing_teams_channel_sync_binding}
end
