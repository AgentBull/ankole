defmodule Ankole.Plugins.Microsoft365Adapter.Jobs.RefreshChannel do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      keys: [:agent_uid, :binding_name, :conversation_id],
      period: 300
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "agent_uid" => agent_uid,
          "binding_name" => binding_name,
          "conversation_id" => conversation_id
        }
      }),
      do:
        Ankole.Plugins.Microsoft365Adapter.TeamsChannels.refresh_conversation(
          agent_uid,
          binding_name,
          conversation_id
        )

  def perform(%Oban.Job{}), do: {:error, :missing_teams_conversation_refresh_binding}
end
