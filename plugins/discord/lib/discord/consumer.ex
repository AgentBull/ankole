defmodule Discord.Consumer do
  @moduledoc """
  Nostrum consumer for BullX Discord sources.

  Each `Nostrum.Bot` started under `Discord.Supervisor` registers this module
  as its consumer. The Nostrum event runtime sets the bot name in the calling
  process dictionary; this module looks the bot name up in `Discord.Registry`
  to find the owning `Discord.Channel` and forwards the event there.

  Per the design doc, the consumer is intentionally thin. Mapping, attention,
  account gate, auto-thread, and publish all live in `Discord.Channel`.
  """

  @behaviour Nostrum.Consumer

  @impl Nostrum.Consumer
  def handle_event(event) do
    bot_name = current_bot_name()

    case bot_name do
      nil ->
        :ok

      bot_name when is_atom(bot_name) ->
        _result = Discord.Channel.dispatch_by_bot_name(bot_name, event)
        :ok
    end
  end

  defp current_bot_name do
    cond do
      function_exported?(Nostrum.Bot, :get_bot_name, 0) -> Nostrum.Bot.get_bot_name()
      true -> Process.get(:nostrum_bot)
    end
  rescue
    _exception -> nil
  end
end
