defmodule BullXTelegram.AttentionPolicy do
  @moduledoc """
  User-facing attention policy for Telegram inbound updates.
  """

  alias BullXTelegram.Config

  @type result :: {:ok, String.t()} | {:ignore, atom()}

  @spec message_attention(map(), Config.t()) :: result()
  def message_attention(message, %Config{} = config) when is_map(message) do
    cond do
      bot_author?(message, config) ->
        {:ignore, :bot_author}

      ignored_chat?(message, config) ->
        {:ignore, :ignored_chat}

      ignored_thread?(message, config) ->
        {:ignore, :ignored_thread}

      outside_allowlist?(message, config) ->
        {:ignore, :outside_allowlist}

      private_chat?(message) ->
        {:ok, "dm"}

      command_for_bot?(message, config) ->
        {:ok, "command"}

      slash_command?(message) ->
        {:ignore, :unsupported_command}

      mentions_bot?(message, config) ->
        {:ok, "mention"}

      replies_to_bot?(message, config) ->
        {:ok, "reply_to_bot"}

      free_response_chat?(message, config) ->
        {:ok, "free_response"}

      config.attention.require_mention == false ->
        {:ok, "free_response"}

      true ->
        {:ignore, :unmentioned_group_message}
    end
  end

  def message_attention(_message, %Config{}), do: {:ignore, :unsupported_message}

  @spec command_for_bot?(map(), Config.t()) :: boolean()
  def command_for_bot?(message, %Config{} = config) do
    message
    |> text_content()
    |> BullXTelegram.DirectCommand.parse(config)
    |> case do
      {:ok, %{name: name}} when name in ["ping", "preauth", "web_auth", "ask"] -> true
      {:ok, _parsed} -> false
      :error -> false
    end
  end

  @spec mentions_bot?(map(), Config.t()) :: boolean()
  def mentions_bot?(message, %Config{bot_username: username}) when is_binary(username) do
    text =
      message
      |> text_content()

    Regex.match?(~r/(^|[^\w])@#{Regex.escape(username)}($|[^\w])/i, text)
  end

  def mentions_bot?(_message, %Config{}), do: false

  defp bot_author?(message, %Config{bot_id: bot_id}) do
    actor = field(message, :from)

    cond do
      field(actor, :is_bot) == true and id_string(field(actor, :id)) == bot_id -> true
      field(actor, :is_bot) == true and is_nil(bot_id) -> true
      field(actor, :is_bot) == true -> true
      is_binary(bot_id) and id_string(field(actor, :id)) == bot_id -> true
      true -> false
    end
  end

  defp ignored_chat?(message, %Config{attention: %{ignored_chat_ids: ignored}}) do
    chat_id(message) in ignored
  end

  defp ignored_thread?(message, %Config{attention: %{ignored_thread_ids: ignored}}) do
    thread_id(message) in ignored
  end

  defp outside_allowlist?(_message, %Config{attention: %{allowed_chat_ids: []}}), do: false

  defp outside_allowlist?(message, %Config{attention: %{allowed_chat_ids: allowed}}) do
    chat_id(message) not in allowed
  end

  defp private_chat?(message), do: chat_type(message) == "private"

  defp slash_command?(message) do
    message
    |> text_content()
    |> String.trim()
    |> String.starts_with?("/")
  end

  defp replies_to_bot?(message, %Config{bot_id: bot_id}) do
    from =
      message
      |> field(:reply_to_message)
      |> field(:from)

    cond do
      field(from, :is_bot) != true -> false
      is_binary(bot_id) -> id_string(field(from, :id)) == bot_id
      true -> true
    end
  end

  defp free_response_chat?(message, %Config{attention: %{free_response_chat_ids: chats}}) do
    chat_id(message) in chats
  end

  defp chat_id(message), do: message |> field(:chat) |> field(:id) |> id_string()
  defp thread_id(message), do: message |> field(:message_thread_id) |> id_string()
  defp chat_type(message), do: message |> field(:chat) |> field(:type)

  defp text_content(message) do
    to_string(field(message, :text) || field(message, :caption) || "")
  end

  defp field(%{} = map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp id_string(nil), do: nil
  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: to_string(value)
end
