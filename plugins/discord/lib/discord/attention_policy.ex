defmodule Discord.AttentionPolicy do
  @moduledoc false

  @spec decide(map(), Discord.Source.t(), term()) :: {:ok, String.t()} | {:ignore, atom()}
  def decide(%{} = message, %Discord.Source{} = source, command_result) do
    channel_id = stringify_id(Map.get(message, "channel_id"))
    guild_id = stringify_id(Map.get(message, "guild_id"))

    cond do
      bot_or_webhook_author?(message) ->
        {:ignore, :bot_author}

      channel_id in source.attention["ignored_channel_ids"] ->
        {:ignore, :ignored_channel}

      channel_id in source.attention["ignored_thread_ids"] ->
        {:ignore, :ignored_thread}

      source.attention["allowed_channel_ids"] != [] and channel_id not in source.attention["allowed_channel_ids"] ->
        {:ignore, :outside_allowlist}

      is_nil(guild_id) ->
        {:ok, "dm"}

      command?(command_result) ->
        {:ok, "application_command"}

      mentions_bot?(message, source) ->
        {:ok, "mention"}

      channel_id in source.attention["free_response_channel_ids"] or source.attention["require_mention"] == false ->
        {:ok, "free_response"}

      true ->
        {:ignore, :unmentioned_guild_message}
    end
  end

  defp command?({:eventbus, _command}), do: true
  defp command?({:direct, _command}), do: true
  defp command?(_command), do: false

  defp bot_or_webhook_author?(%{"webhook_id" => webhook_id}) when is_binary(webhook_id) and webhook_id != "", do: true
  defp bot_or_webhook_author?(%{"author" => %{"bot" => true}}), do: true
  defp bot_or_webhook_author?(%{"author" => %{"system" => true}}), do: true
  defp bot_or_webhook_author?(_message), do: false

  defp mentions_bot?(_message, %Discord.Source{bot_user_id: nil}), do: false

  defp mentions_bot?(message, %Discord.Source{bot_user_id: bot_user_id}) do
    mentioned_ids =
      message
      |> Map.get("mentions", [])
      |> Enum.map(&stringify_id(Map.get(&1, "id")))

    bot_user_id in mentioned_ids or
      (Map.get(message, "content", "") |> to_string() |> String.contains?("<@#{bot_user_id}>")) or
      (Map.get(message, "content", "") |> to_string() |> String.contains?("<@!#{bot_user_id}>"))
  end

  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(value) when is_binary(value), do: value
  defp stringify_id(_value), do: nil
end
