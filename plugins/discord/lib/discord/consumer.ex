defmodule Discord.Consumer do
  @moduledoc false

  @behaviour Nostrum.Consumer

  @impl Nostrum.Consumer
  def handle_event(event) do
    case current_bot_name() do
      bot_name when is_atom(bot_name) -> Discord.Channel.dispatch_by_bot_name(bot_name, event)
      _value -> :ok
    end

    :ok
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
