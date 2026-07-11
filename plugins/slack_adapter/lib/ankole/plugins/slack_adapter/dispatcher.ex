defmodule Ankole.Plugins.SlackAdapter.Dispatcher do
  @moduledoc false

  alias Ankole.Plugins.SlackAdapter.{Channels, IdentityProvider, Inbound}
  alias SlackOpenAPI.Event
  alias SlackOpenAPI.SocketMode.Dispatcher, as: SocketDispatcher

  @message_events ["message", "reaction_added", "reaction_removed"]
  @channel_events [
    "member_joined_channel",
    "member_left_channel",
    "channel_rename",
    "channel_deleted",
    "channel_archive"
  ]
  @contact_events [
    "team_join",
    "user_change",
    "subteam_created",
    "subteam_updated",
    "subteam_members_changed"
  ]

  @spec event_types() :: [String.t()]
  def event_types, do: @message_events ++ @channel_events ++ @contact_events ++ ["block_actions"]

  @spec build([map()], keyword()) :: SocketDispatcher.t()
  def build(consumers, _opts \\ []) do
    SocketDispatcher.new()
    |> SocketDispatcher.on("message", handler(consumers, &Inbound.handle_message_receive/3))
    |> SocketDispatcher.on(
      "reaction_added",
      handler(consumers, &Inbound.handle_reaction_created/3)
    )
    |> SocketDispatcher.on(
      "reaction_removed",
      handler(consumers, &Inbound.handle_reaction_deleted/3)
    )
    |> SocketDispatcher.on_interactive(
      "block_actions",
      handler(consumers, &Inbound.handle_card_action/3)
    )
    |> register(@channel_events, consumers, &Channels.handle_im_event/3)
    |> register(@contact_events, consumers, &IdentityProvider.handle_contact_event/3)
  end

  defp register(dispatcher, event_types, consumers, fun) do
    Enum.reduce(event_types, dispatcher, fn event_type, acc ->
      SocketDispatcher.on(acc, event_type, handler(consumers, fun))
    end)
  end

  defp handler(consumers, fun) do
    fn event_type, %Event{} = event -> fun.(event_type, event, consumers) end
  end
end
