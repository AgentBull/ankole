defmodule BullxTelegram.AttentionPolicy do
  @moduledoc """
  Group-chat attention policy for Telegram inbound updates.

  Returns one of the documented reason atoms (`"dm"`, `"command"`, `"mention"`,
  `"reply_to_bot"`, `"free_response"`) for updates the source should process,
  or `{:ignore, reason}` for updates to drop before publish.
  """

  alias BullxTelegram.{DirectCommand, Source}

  @type result :: {:ok, String.t()} | {:ignore, atom()}

  @spec message_attention(map(), Source.t()) :: result()
  def message_attention(message, %Source{} = source) when is_map(message) do
    cond do
      bot_author?(message, source) ->
        {:ignore, :bot_author}

      anonymous?(message) ->
        {:ignore, :anonymous_sender}

      ignored_chat?(message, source) ->
        {:ignore, :ignored_chat}

      ignored_thread?(message, source) ->
        {:ignore, :ignored_thread}

      outside_allowlist?(message, source) ->
        {:ignore, :outside_allowlist}

      private_chat?(message) ->
        {:ok, "dm"}

      command_for_bot?(message, source) ->
        {:ok, "command"}

      command_for_other_bot?(message, source) ->
        {:ignore, :command_for_other_bot}

      mentions_bot?(message, source) ->
        {:ok, "mention"}

      replies_to_bot?(message, source) ->
        {:ok, "reply_to_bot"}

      free_response_chat?(message, source) ->
        {:ok, "free_response"}

      source.attention["require_mention"] == false ->
        {:ok, "free_response"}

      slash_command?(message) ->
        {:ignore, :unsupported_command}

      true ->
        {:ignore, :unmentioned_group_message}
    end
  end

  def message_attention(_message, %Source{}), do: {:ignore, :unsupported_message}

  @spec command_for_bot?(map(), Source.t()) :: boolean()
  def command_for_bot?(message, %Source{} = source) do
    case DirectCommand.parse(text_content(message), source) do
      {:ok, _parsed} -> true
      _other -> false
    end
  end

  @spec mentions_bot?(map(), Source.t()) :: boolean()
  def mentions_bot?(message, %Source{bot_username: username}) when is_binary(username) do
    text = text_content(message)
    Regex.match?(~r/(^|[^\w])@#{Regex.escape(username)}($|[^\w])/i, text)
  end

  def mentions_bot?(_message, %Source{}), do: false

  defp bot_author?(message, %Source{bot_id: bot_id}) do
    actor = field(message, :from)

    cond do
      field(actor, :is_bot) != true -> false
      is_binary(bot_id) and id_string(field(actor, :id)) == bot_id -> true
      true -> false
    end
  end

  defp anonymous?(message), do: is_nil(field(message, :from))

  defp ignored_chat?(message, %Source{attention: %{"ignored_chat_ids" => ignored}}) do
    id = to_string(chat_id(message))
    id != "" and id in ignored
  end

  defp ignored_thread?(message, %Source{attention: %{"ignored_thread_ids" => ignored}}) do
    case thread_id(message) do
      nil -> false
      thread -> to_string(thread) in ignored
    end
  end

  defp outside_allowlist?(_message, %Source{attention: %{"allowed_chat_ids" => []}}), do: false

  defp outside_allowlist?(message, %Source{attention: %{"allowed_chat_ids" => allowed}}) do
    to_string(chat_id(message)) not in allowed
  end

  defp private_chat?(message), do: chat_type(message) == "private"

  defp command_for_other_bot?(message, %Source{} = source) do
    case DirectCommand.parse(text_content(message), source) do
      {:error_other_bot, _name} -> true
      _other -> false
    end
  end

  defp replies_to_bot?(message, %Source{bot_id: bot_id}) do
    from =
      message
      |> field(:reply_to_message)
      |> field(:from)

    cond do
      field(from, :is_bot) != true -> false
      is_binary(bot_id) -> id_string(field(from, :id)) == bot_id
      true -> false
    end
  end

  defp free_response_chat?(message, %Source{attention: %{"free_response_chat_ids" => chats}}) do
    to_string(chat_id(message)) in chats
  end

  defp slash_command?(message) do
    message
    |> text_content()
    |> String.trim()
    |> String.starts_with?("/")
  end

  defp text_content(message) do
    case field(message, :text) do
      text when is_binary(text) -> text
      _value -> field(message, :caption) || ""
    end
  end

  defp chat_id(message) do
    case field(message, :chat) do
      %{} = chat -> field(chat, :id)
      _other -> nil
    end
  end

  defp chat_type(message) do
    case field(message, :chat) do
      %{} = chat -> field(chat, :type)
      _other -> nil
    end
  end

  defp thread_id(message), do: field(message, :message_thread_id)

  defp field(%{} = map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
