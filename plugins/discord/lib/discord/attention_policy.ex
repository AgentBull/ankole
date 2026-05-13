defmodule Discord.AttentionPolicy do
  @moduledoc """
  Filter Discord inbound events before publish.

  Returns one of the documented attention reasons (`"dm"`, `"mention"`,
  `"application_command"`, `"owned_thread"`, `"free_response"`) or
  `{:ignore, reason}` for events to drop.

  The policy is invoked from `Discord.EventMapper` after the self-author and
  webhook-author filters have already run.
  """

  alias Discord.{Source, ThreadOwnership}

  @thread_types [10, 11, 12]

  @type result :: {:ok, String.t()} | {:ignore, atom()}

  @spec message_attention(map(), Source.t()) :: result()
  def message_attention(message, %Source{} = source) when is_map(message) do
    cond do
      ignored_channel?(message, source) ->
        {:ignore, :ignored_channel}

      ignored_thread?(message, source) ->
        {:ignore, :ignored_thread}

      outside_allowlist?(message, source) ->
        {:ignore, :outside_allowlist}

      dm?(message) ->
        {:ok, "dm"}

      mentions_bot?(message, source) ->
        {:ok, "mention"}

      in_thread?(message) ->
        owned_thread_attention(message, source)

      channel_in_free_response?(message, source) ->
        {:ok, "free_response"}

      source.attention["require_mention"] == false ->
        {:ok, "free_response"}

      slash_command?(message) ->
        {:ignore, :unsupported_command}

      true ->
        {:ignore, :unmentioned_guild_message}
    end
  end

  def message_attention(_message, %Source{}), do: {:ignore, :unsupported_message}

  @spec interaction_attention(map(), Source.t()) :: result()
  def interaction_attention(interaction, %Source{} = source) when is_map(interaction) do
    cond do
      ignored_channel?(interaction, source) ->
        {:ignore, :ignored_channel}

      outside_allowlist?(interaction, source) ->
        {:ignore, :outside_allowlist}

      true ->
        {:ok, "application_command"}
    end
  end

  def interaction_attention(_interaction, %Source{}),
    do: {:ignore, :unsupported_interaction}

  @spec mentions_bot?(map(), Source.t()) :: boolean()
  def mentions_bot?(message, %Source{bot_user_id: bot_user_id}) when is_binary(bot_user_id) do
    mention_ids(message)
    |> Enum.any?(&(&1 == bot_user_id))
  end

  def mentions_bot?(_message, %Source{}), do: false

  defp ignored_channel?(event, %Source{attention: %{"ignored_channel_ids" => ignored}}) do
    channel = channel_id(event)
    channel != "" and channel in ignored
  end

  defp ignored_thread?(message, %Source{attention: %{"ignored_thread_ids" => ignored}}) do
    case in_thread?(message) do
      false -> false
      true -> channel_id(message) in ignored
    end
  end

  defp outside_allowlist?(_event, %Source{attention: %{"allowed_channel_ids" => []}}), do: false

  defp outside_allowlist?(event, %Source{attention: %{"allowed_channel_ids" => allowed}}) do
    channel_id(event) not in allowed
  end

  defp dm?(message), do: is_nil(guild_id(message))

  defp owned_thread_attention(message, %Source{} = source) do
    case ThreadOwnership.owned?(channel_id(message), source) do
      {:ok, true} -> {:ok, "owned_thread"}
      {:ok, false} -> {:ignore, :unmentioned_guild_message}
      {:error, _error} -> {:ignore, :thread_ownership_unresolved}
    end
  end

  defp in_thread?(message) do
    case Map.get(message, :type) || Map.get(message, "type") do
      type when is_integer(type) -> type in @thread_types
      _other -> false
    end
  end

  defp channel_in_free_response?(message, %Source{
         attention: %{"free_response_channel_ids" => channels}
       }) do
    channel_id(message) in channels
  end

  defp slash_command?(message) do
    message
    |> text_content()
    |> String.trim()
    |> String.starts_with?("/")
  end

  defp text_content(message), do: to_string(field(message, :content) || "")

  defp mention_ids(message) do
    message
    |> field(:mentions)
    |> case do
      mentions when is_list(mentions) -> Enum.map(mentions, &id_string(field(&1, :id)))
      _other -> []
    end
  end

  defp channel_id(event) do
    event
    |> field(:channel_id)
    |> id_string()
    |> Kernel.||("")
  end

  defp guild_id(event), do: field(event, :guild_id)

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
