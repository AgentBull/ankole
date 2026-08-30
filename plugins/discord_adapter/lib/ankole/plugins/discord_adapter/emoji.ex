defmodule Ankole.Plugins.DiscordAdapter.Emoji do
  @moduledoc false

  @aliases %{
    "+1" => "👍",
    "thumbsup" => "👍",
    "-1" => "👎",
    "thumbsdown" => "👎",
    "heart" => "❤️",
    "fire" => "🔥",
    "tada" => "🎉",
    "laugh" => "😁",
    "thinking" => "🤔",
    "eyes" => "👀",
    "rocket" => "🚀"
  }

  @doc """
  Returns `{reaction_key, raw_reaction_key}` for one gateway reaction emoji.

  A custom guild emoji keys on its snowflake, because two guilds can give
  different images the same name. Its raw key keeps the `name:id` form that the
  REST reaction endpoints need. A Unicode emoji is its own key.
  """
  @spec reaction_key(map()) :: {String.t(), String.t()} | :error
  def reaction_key(%{"id" => id, "name" => name}) when is_binary(id) and is_binary(name),
    do: {"discord_custom:#{id}", "#{name}:#{id}"}

  def reaction_key(%{"name" => name}) when is_binary(name), do: {name, name}
  def reaction_key(_emoji), do: :error

  @spec provider_key(term()) :: String.t()
  def provider_key(value) when is_binary(value), do: Map.get(@aliases, value, value)
  def provider_key(value), do: to_string(value)

  @doc """
  Returns the URL path form the reaction endpoints require. A Unicode emoji is
  percent-encoded. A custom emoji arrives as `name:id` and keeps its colon,
  which the path grammar allows.
  """
  @spec path_segment(term()) :: String.t()
  def path_segment(value) do
    value
    |> provider_key()
    |> URI.encode(&(URI.char_unreserved?(&1) or &1 == ?:))
  end
end
