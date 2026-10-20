defmodule Ankole.Plugins.SlackAdapter.Dispatcher do
  @moduledoc false

  alias Ankole.Plugins.SlackAdapter.Channels
  alias Ankole.Plugins.SlackAdapter.IdentityProvider
  alias Ankole.Plugins.SlackAdapter.Inbound
  alias SlackOpenAPI.Event
  alias SlackOpenAPI.SocketMode.Dispatcher, as: SocketDispatcher

  @message_receive_events ["message", "app_mention"]
  @channel_events [
    "member_joined_channel",
    "member_left_channel",
    "channel_rename",
    "group_rename",
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

  @spec build([map()], keyword()) :: SocketDispatcher.t()
  def build(consumers, _opts \\ []) do
    SocketDispatcher.new()
    |> register(@message_receive_events, consumers, &Inbound.handle_message_receive/3)
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
      handler(consumers, &Inbound.handle_block_action/3)
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
    tenant_id = Ankole.Plugins.ConnectionLifecycle.tenant_id!(consumers)

    fn event_type, %Event{} = event ->
      Ankole.Tenants.dispatch_inbound(tenant_id, fn -> fun.(event_type, event, consumers) end)
    end
  end
end
