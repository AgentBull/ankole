defmodule Ankole.Plugins.LineAdapter.Presentation do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.Plugins.UTF16Text
  alias Ankole.Conversations.Delivery.ActionToken
  alias Ankole.Conversations.Delivery.ReplyPresentation

  @text_units 5_000
  @alt_text_units 400
  @template_text_units 160
  @label_units 20
  @buttons_per_template 4
  @postback_data_bytes 300
  @messages_per_request 5

  @chat_types ["user", "group", "room"]

  @spec conversation_id(String.t(), String.t(), String.t()) :: String.t()
  def conversation_id(bot_user_id, chat_type, chat_id) when chat_type in @chat_types,
    do: "line:#{bot_user_id}:#{chat_type}:#{chat_id}"

  @spec parse_channel(term()) ::
          {:ok, %{bot_user_id: String.t(), chat_type: String.t(), chat_id: String.t()}}
          | {:error, :invalid_line_channel_id}
  def parse_channel("line:" <> rest) do
    case String.split(rest, ":") do
      [bot_user_id, chat_type, chat_id]
      when bot_user_id != "" and chat_type in @chat_types and chat_id != "" ->
        {:ok, %{bot_user_id: bot_user_id, chat_type: chat_type, chat_id: chat_id}}

      _invalid ->
        {:error, :invalid_line_channel_id}
    end
  end

  def parse_channel(_channel_id), do: {:error, :invalid_line_channel_id}

  @doc "Text messages for one reply; the first one quotes `quote_token` when given."
  @spec text_messages(term(), String.t() | nil) :: [map()]
  def text_messages(text, quote_token \\ nil) do
    text
    |> chunks()
    |> Enum.with_index()
    |> Enum.map(fn
      {chunk, 0} -> maybe_quote(%{"type" => "text", "text" => chunk}, quote_token)
      {chunk, _index} -> %{"type" => "text", "text" => chunk}
    end)
  end

  @doc """
  Buttons templates for the pending actions of one reply presentation.

  A buttons template carries at most four postback actions and a short prompt,
  so a longer action list becomes several templates under the same prompt.
  """
  @spec action_messages(map(), String.t()) :: [map()]
  def action_messages(presentation, signal_id)
      when is_map(presentation) and is_binary(signal_id) do
    case ReplyPresentation.normalize(presentation) do
      %{"interaction_status" => "pending", "actions" => actions} = normalized
      when is_list(actions) ->
        prompt = template_text(normalized)

        actions
        |> Enum.with_index()
        |> Enum.flat_map(&button(&1, signal_id))
        |> Enum.chunk_every(@buttons_per_template)
        |> Enum.map(&template(prompt, &1))

      _presentation ->
        []
    end
  end

  def action_messages(_presentation, _signal_id), do: []

  @spec chunks(term()) :: [String.t()]
  def chunks(value) do
    case UTF16Text.chunks(to_string(value), @text_units) do
      [] -> [I18n.t("conversations.delivery.reply.no_content")]
      values -> values
    end
  end

  @spec batches([map()]) :: [[map()]]
  def batches(messages) when is_list(messages),
    do: Enum.chunk_every(messages, @messages_per_request)

  defp template_text(presentation) do
    prompt =
      case presentation["prompt"] do
        text when is_binary(text) and text != "" ->
          Ankole.Plugins.MarkdownChunks.unescape_plain_tildes(text)

        _missing ->
          presentation
          |> ReplyPresentation.fallback_text()
          |> Ankole.Plugins.MarkdownChunks.unescape_plain_tildes()
      end

    case truncate(prompt, @template_text_units) do
      "" -> I18n.t("conversations.delivery.reply.needs_input")
      text -> text
    end
  end

  defp button({%{"type" => "button", "disabled" => true}, _index}, _event_id), do: []

  defp button({%{"type" => "button"} = action, index}, event_id) do
    with label when is_binary(label) and label != "" <- action["label"],
         {:ok, token} <-
           ActionToken.encode(event_id, index, action,
             prefix: "ln1",
             max_bytes: @postback_data_bytes,
             too_long_error: :postback_data_too_long
           ) do
      label = truncate(label, @label_units)
      [%{"type" => "postback", "label" => label, "data" => token, "displayText" => label}]
    else
      _invalid -> []
    end
  end

  defp button({_action, _index}, _event_id), do: []

  defp template(text, actions) do
    %{
      "type" => "template",
      "altText" => truncate(text, @alt_text_units),
      "template" => %{"type" => "buttons", "text" => text, "actions" => actions}
    }
  end

  defp maybe_quote(message, token) when is_binary(token) and token != "",
    do: Map.put(message, "quoteToken", token)

  defp maybe_quote(message, _token), do: message

  defp truncate(text, units) do
    text
    |> to_string()
    |> String.trim()
    |> UTF16Text.chunks(units)
    |> List.first()
    |> Kernel.||("")
  end
end
