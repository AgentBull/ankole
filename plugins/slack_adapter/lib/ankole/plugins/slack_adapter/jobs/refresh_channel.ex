defmodule Ankole.Plugins.SlackAdapter.Jobs.RefreshChannel do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      keys: [:agent_uid, :binding_name, :channel_id],
      period: 300
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "agent_uid" => agent_uid,
          "binding_name" => binding_name,
          "channel_id" => channel_id
        }
      }),
      do:
        Ankole.Plugins.SlackAdapter.Channels.refresh_channel(agent_uid, binding_name, channel_id)

  def perform(%Oban.Job{}), do: {:error, :missing_slack_channel_refresh_binding}
end
