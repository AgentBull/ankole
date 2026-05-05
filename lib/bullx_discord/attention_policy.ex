defmodule BullXDiscord.AttentionPolicy do
  @moduledoc """
  User-facing attention policy for Discord inbound events.
  """

  alias BullXDiscord.{Cache, Config, ThreadOwnership}

  @type result :: {:ok, String.t(), Cache.t()} | {:ignore, atom(), Cache.t()}

  @spec message_attention(term(), Config.t(), Cache.t()) :: result()
  def message_attention(message, %Config{} = config, %Cache{} = cache) do
    cond do
      bot_author?(message, config) ->
        {:ignore, :bot_author, cache}

      ignored_channel?(message, config) ->
        {:ignore, :ignored_channel, cache}

      outside_allowlist?(message, config) ->
        {:ignore, :outside_allowlist, cache}

      dm?(message) ->
        {:ok, "dm", cache}

      mentioned_bot?(message, config) ->
        {:ok, "mention", cache}

      true ->
        owned_thread_attention(message, config, cache)
    end
  end

  @spec interaction_attention(term(), Config.t(), Cache.t()) :: result()
  def interaction_attention(interaction, %Config{} = config, %Cache{} = cache) do
    cond do
      ignored_channel?(interaction, config) ->
        {:ignore, :ignored_channel, cache}

      outside_allowlist?(interaction, config) ->
        {:ignore, :outside_allowlist, cache}

      true ->
        {:ok, "application_command", cache}
    end
  end

  @spec mentioned_bot?(term(), Config.t()) :: boolean()
  def mentioned_bot?(message, %Config{bot_user_id: bot_user_id}) when is_binary(bot_user_id) do
    mentioned_user_ids(message)
    |> Enum.any?(&(&1 == bot_user_id))
  end

  def mentioned_bot?(message, %Config{}) do
    Regex.match?(~r/<@!?\d+>/, text_content(message))
  end

  defp owned_thread_attention(message, config, cache) do
    case ThreadOwnership.owned?(channel_id(message), config, cache) do
      {:ok, true, cache} -> {:ok, "owned_thread", cache}
      {:ok, false, cache} -> {:ignore, :unmentioned_guild_message, cache}
      {:error, _error, cache} -> {:ignore, :thread_ownership_unresolved, cache}
    end
  end

  defp bot_author?(message, %Config{bot_user_id: bot_user_id}) do
    author = author(message)

    cond do
      truthy?(field(author, :bot)) -> true
      is_binary(bot_user_id) and id_string(field(author, :id)) == bot_user_id -> true
      true -> false
    end
  end

  defp ignored_channel?(message, %Config{attention: %{ignored_channel_ids: ignored}}) do
    channel_id(message) in ignored
  end

  defp outside_allowlist?(_message, %Config{attention: %{allowed_channel_ids: []}}), do: false

  defp outside_allowlist?(message, %Config{attention: %{allowed_channel_ids: allowed}}) do
    channel_id(message) not in allowed
  end

  defp dm?(message), do: is_nil(guild_id(message))

  defp mentioned_user_ids(message) do
    message
    |> field(:mentions)
    |> case do
      mentions when is_list(mentions) -> Enum.map(mentions, &id_string(field(&1, :id)))
      _other -> []
    end
  end

  defp author(message), do: field(message, :author) || field(message, :user)
  defp channel_id(message), do: id_string(field(message, :channel_id))
  defp guild_id(message), do: field(message, :guild_id)
  defp text_content(message), do: to_string(field(message, :content) || "")

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)

  defp truthy?(true), do: true
  defp truthy?(_), do: false
end
