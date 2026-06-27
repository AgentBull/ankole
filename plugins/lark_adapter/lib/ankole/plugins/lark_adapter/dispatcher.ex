defmodule Ankole.Plugins.LarkAdapter.Dispatcher do
  @moduledoc """
  Builds the FeishuOpenAPI event dispatcher for Lark adapter consumers.
  """

  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.Event.Dispatcher, as: FeishuDispatcher

  @message_receive "im.message.receive_v1"
  @message_recalled "im.message.recalled_v1"
  @reaction_created "im.message.reaction.created_v1"
  @reaction_deleted "im.message.reaction.deleted_v1"
  @card_action "card.action.trigger"

  @contact_events [
    "contact.user.created_v3",
    "contact.user.updated_v3",
    "contact.user.deleted_v3",
    "contact.department.created_v3",
    "contact.department.updated_v3",
    "contact.department.deleted_v3",
    "contact.scope.updated_v3"
  ]

  @doc """
  Lists every provider event type the adapter registers.
  """
  @spec event_types() :: [String.t()]
  def event_types do
    [
      @message_receive,
      @message_recalled,
      @reaction_created,
      @reaction_deleted,
      @card_action | @contact_events
    ]
  end

  @doc """
  Builds a FeishuOpenAPI dispatcher wired to the supplied chat and identity consumers.
  """
  @spec build([map()], keyword()) :: FeishuDispatcher.t()
  def build(consumers, opts \\ []) when is_list(consumers) do
    opts
    |> Keyword.take([:verification_token, :encrypt_key, :client])
    |> FeishuDispatcher.new()
    |> FeishuDispatcher.on(
      @message_receive,
      handler(consumers, &Inbound.handle_message_receive/3)
    )
    |> FeishuDispatcher.on(
      @message_recalled,
      handler(consumers, &Inbound.handle_message_removed/3)
    )
    |> FeishuDispatcher.on(
      @reaction_created,
      handler(consumers, &Inbound.handle_reaction_created/3)
    )
    |> FeishuDispatcher.on(
      @reaction_deleted,
      handler(consumers, &Inbound.handle_reaction_deleted/3)
    )
    |> FeishuDispatcher.on_callback(
      @card_action,
      handler(consumers, &Inbound.handle_card_action/3)
    )
    |> register_contact_handlers(consumers)
  end

  defp register_contact_handlers(dispatcher, consumers) do
    Enum.reduce(@contact_events, dispatcher, fn event_type, acc ->
      FeishuDispatcher.on(
        acc,
        event_type,
        handler(consumers, &IdentityProvider.handle_contact_event/3)
      )
    end)
  end

  defp handler(consumers, fun) do
    # Consumer data is closed over at dispatcher build time so websocket callbacks
    # stay small and do not need to query plugin state for every provider event.
    fn event_type, %Event{} = event -> fun.(event_type, event, consumers) end
  end
end
