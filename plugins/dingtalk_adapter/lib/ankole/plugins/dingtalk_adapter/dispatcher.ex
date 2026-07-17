defmodule Ankole.Plugins.DingTalkAdapter.Dispatcher do
  @moduledoc """
  Builds the DingTalk Stream dispatcher for the adapter's consumers.

  Chat consumers register the robot message CALLBACK and the card CALLBACK;
  identity consumers register the contact EVENT types. Topics are registered only
  when a consumer needs them, so a chat-only connection never subscribes to the
  EVENT stream and an identity-only connection never subscribes to the message
  callback. The Stream client derives its subscription list from the registered
  topics.
  """

  alias Ankole.Plugins.DingTalkAdapter.IdentityProvider
  alias Ankole.Plugins.DingTalkAdapter.Inbound
  alias DingTalkOpenAPI.Event
  alias DingTalkOpenAPI.Stream.Dispatcher, as: StreamDispatcher

  @message_callback "/v1.0/im/bot/messages/get"
  @card_callback "/v1.0/card/instances/callback"

  @contact_events [
    "user_add_org",
    "user_modify_org",
    "user_leave_org",
    "user_active_org",
    "org_dept_create",
    "org_dept_modify",
    "org_dept_remove",
    "org_admin_add",
    "org_admin_remove",
    "org_remove"
  ]

  @doc "Lists every CALLBACK topic the chat face registers."
  @spec callback_topics() :: [String.t()]
  def callback_topics, do: [@message_callback, @card_callback]

  @doc "Lists every contact EVENT type the identity face registers."
  @spec contact_events() :: [String.t()]
  def contact_events, do: @contact_events

  @doc "Builds a Stream dispatcher wired to the supplied consumers."
  @spec build([map()], keyword()) :: StreamDispatcher.t()
  def build(consumers, _opts \\ []) when is_list(consumers) do
    StreamDispatcher.new()
    |> maybe_register_chat(consumers)
    |> maybe_register_contacts(consumers)
  end

  defp maybe_register_chat(dispatcher, consumers) do
    if Enum.any?(consumers, &match?(%{kind: :chat}, &1)) do
      dispatcher
      |> StreamDispatcher.on_callback(
        @message_callback,
        handler(consumers, &Inbound.handle_message_receive/3)
      )
      |> StreamDispatcher.on_callback(
        @card_callback,
        handler(consumers, &Inbound.handle_card_action/3)
      )
    else
      dispatcher
    end
  end

  defp maybe_register_contacts(dispatcher, consumers) do
    if Enum.any?(consumers, &match?(%{kind: :identity_provider}, &1)) do
      Enum.reduce(@contact_events, dispatcher, fn event_type, acc ->
        StreamDispatcher.on_event(
          acc,
          event_type,
          handler(consumers, &IdentityProvider.handle_contact_event/3)
        )
      end)
    else
      dispatcher
    end
  end

  defp handler(consumers, fun) do
    # Consumer data is closed over at dispatcher build time so Stream callbacks
    # stay small and never query plugin state per frame.
    fn key, %Event{} = event -> fun.(key, event, consumers) end
  end
end
