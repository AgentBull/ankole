defmodule Ankole.Plugins.TelegramAdapter.Emoji do
  @moduledoc false

  @aliases %{
    "+1" => "👍",
    "thumbsup" => "👍",
    "-1" => "👎",
    "thumbsdown" => "👎",
    "heart" => "❤",
    "fire" => "🔥",
    "tada" => "🎉",
    "laugh" => "😁",
    "thinking" => "🤔",
    "eyes" => "👀",
    "rocket" => "🚀"
  }

  @spec provider_key(term()) :: String.t()
  def provider_key(value) when is_binary(value), do: Map.get(@aliases, value, value)
  def provider_key(value), do: to_string(value)
end
