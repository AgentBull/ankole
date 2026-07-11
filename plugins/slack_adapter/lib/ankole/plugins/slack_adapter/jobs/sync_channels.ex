defmodule Ankole.Plugins.SlackAdapter.Jobs.SyncChannels do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [fields: [:worker, :args], keys: [:agent_uid, :binding_name], period: 300]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"agent_uid" => agent_uid, "binding_name" => binding_name}}),
    do: Ankole.Plugins.SlackAdapter.Channels.sync_binding(agent_uid, binding_name)

  def perform(%Oban.Job{}), do: {:error, :missing_slack_channel_sync_binding}
end
