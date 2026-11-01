defmodule Ankole.Plugins.Microsoft365Adapter.Jobs.RefreshChannel do
  @moduledoc false

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      keys: [:binding_id, :conversation_id],
      period: 300
    ]

  @impl Ankole.Job
  def run(%Oban.Job{
        args: %{
          "binding_id" => binding_id,
          "conversation_id" => conversation_id
        }
      }),
      do:
        Ankole.Plugins.Microsoft365Adapter.TeamsChannels.refresh_conversation(
          binding_id,
          conversation_id
        )

  def run(%Oban.Job{}), do: {:error, :missing_teams_conversation_refresh_binding}
end
