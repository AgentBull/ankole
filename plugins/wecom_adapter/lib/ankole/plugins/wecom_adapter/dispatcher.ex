defmodule Ankole.Plugins.WeComAdapter.Dispatcher do
  @moduledoc """
  Builds the bot channel dispatcher for the adapter's chat consumers.

  Message callbacks route to `Inbound.handle_message_receive/3`; the
  `template_card_event` routes to `Inbound.handle_card_action/3`. Other event
  types (`enter_chat`, `feedback_event`) stay unregistered and are dropped by
  the lib dispatcher; `disconnected_event` never reaches it (the client
  consumes it as the connection-contended signal).
  """

  alias Ankole.Plugins.WeComAdapter.Inbound
  alias WeComOpenAPI.Bot.Dispatcher, as: BotDispatcher
  alias WeComOpenAPI.Bot.Event

  @doc "Builds a bot dispatcher wired to the supplied consumers."
  @spec build([map()]) :: BotDispatcher.t()
  def build(consumers) when is_list(consumers) do
    chat_consumers = Enum.filter(consumers, &match?(%{kind: :chat}, &1))

    case chat_consumers do
      [] ->
        BotDispatcher.new()

      _present ->
        BotDispatcher.new()
        |> BotDispatcher.on_message(
          handler("aibot_msg_callback", chat_consumers, &Inbound.handle_message_receive/3)
        )
        |> BotDispatcher.on_event(
          "template_card_event",
          handler("template_card_event", chat_consumers, &Inbound.handle_card_action/3)
        )
    end
  end

  defp handler(event_type, consumers, fun) do
    # Consumer data is closed over at dispatcher build time so bot callbacks
    # stay small and never query plugin state per frame.
    fn %Event{} = event -> fun.(event_type, event, consumers) end
  end
end
