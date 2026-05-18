defmodule BullxTelegram.AttentionPolicy do
  @moduledoc false

  @type decision :: {:ok, String.t()} | {:ignore, atom()}

  @spec decide(map(), BullxTelegram.Source.t(), term()) :: decision()
  def decide(%{} = message, %BullxTelegram.Source{} = source, command_result) do
    chat = Map.get(message, "chat") || %{}
    from = Map.get(message, "from") || %{}
    chat_id = stringify_id(Map.get(chat, "id"))
    thread_id = stringify_id(Map.get(message, "message_thread_id"))
    chat_type = Map.get(chat, "type")

    cond do
      from == %{} ->
        {:ignore, :anonymous_actor}

      bot_author?(from, source) ->
        {:ignore, :bot_author}

      chat_id in source.attention["ignored_chat_ids"] ->
        {:ignore, :ignored_chat}

      present?(thread_id) and thread_id in source.attention["ignored_thread_ids"] ->
        {:ignore, :ignored_thread}

      source.attention["allowed_chat_ids"] != [] and chat_id not in source.attention["allowed_chat_ids"] ->
        {:ignore, :outside_allowlist}

      chat_type == "private" ->
        {:ok, "dm"}

      command?(command_result) ->
        {:ok, "command"}

      mentions_bot?(message, source) ->
        {:ok, "mention"}

      reply_to_bot?(message, source) ->
        {:ok, "reply_to_bot"}

      chat_id in source.attention["free_response_chat_ids"] or source.attention["require_mention"] == false ->
        {:ok, "free_response"}

      true ->
        {:ignore, :unmentioned_group_message}
    end
  end

  defp command?({:eventbus, _command}), do: true
  defp command?({:direct, _command}), do: true
  defp command?(_result), do: false

  defp bot_author?(%{"is_bot" => true} = from, %BullxTelegram.Source{} = source) do
    stringify_id(Map.get(from, "id")) == source.bot_id or true
  end

  defp bot_author?(_from, _source), do: false

  defp mentions_bot?(_message, %BullxTelegram.Source{bot_username: nil}), do: false

  defp mentions_bot?(message, %BullxTelegram.Source{bot_username: username}) do
    text = (Map.get(message, "text") || Map.get(message, "caption") || "") |> String.downcase()
    String.contains?(text, "@" <> String.downcase(username))
  end

  defp reply_to_bot?(%{"reply_to_message" => %{"from" => from}}, %BullxTelegram.Source{} = source) do
    stringify_id(Map.get(from, "id")) == source.bot_id
  end

  defp reply_to_bot?(_message, _source), do: false
  defp stringify_id(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify_id(value) when is_binary(value), do: value
  defp stringify_id(_value), do: nil
  defp present?(value), do: is_binary(value) and value != ""
end
