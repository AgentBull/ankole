defmodule Ankole.Plugins.WhatsAppAdapter.Presentation do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.SignalsGateway.ReplyActionToken
  alias Ankole.SignalsGateway.ReplyPresentation

  @text_chars 4_096
  @body_chars 1_024
  @caption_chars 1_024
  @button_title_chars 20
  @row_title_chars 24
  @row_description_chars 72
  @list_button_chars 20
  @reply_buttons 3
  @token_bytes 256

  @spec signal_channel_id(String.t(), String.t()) :: String.t()
  def signal_channel_id(phone_number_id, wa_id)
      when is_binary(phone_number_id) and is_binary(wa_id),
      do: "whatsapp:#{phone_number_id}:#{wa_id}"

  @spec parse_channel(term()) ::
          {:ok, %{phone_number_id: String.t(), wa_id: String.t()}}
          | {:error, :invalid_whatsapp_channel_id}
  def parse_channel("whatsapp:" <> rest) do
    case String.split(rest, ":") do
      [phone_number_id, wa_id] when phone_number_id != "" and wa_id != "" ->
        {:ok, %{phone_number_id: phone_number_id, wa_id: wa_id}}

      _invalid ->
        {:error, :invalid_whatsapp_channel_id}
    end
  end

  def parse_channel(_channel_id), do: {:error, :invalid_whatsapp_channel_id}

  @doc "Text message bodies for one reply, split at the Cloud API text limit."
  @spec text_messages(term()) :: [map()]
  def text_messages(text) do
    Enum.map(chunks(text), &%{"type" => "text", "text" => %{"body" => &1}})
  end

  @doc "Splits text into chunks of at most `limit` characters without breaking a grapheme."
  @spec chunks(term(), pos_integer()) :: [String.t()]
  def chunks(value, limit \\ @text_chars) do
    case to_string(value) do
      "" -> [I18n.t("signals_gateway.reply.no_content")]
      text -> split(text, limit)
    end
  end

  @doc """
  Splits reply text into the first attachment caption and the remaining text.

  An attachment row normally carries no text, and an empty caption is left out
  of the message instead of becoming a placeholder line.
  """
  @spec split_caption(term()) :: {String.t(), String.t()}
  def split_caption(value) do
    case to_string(value) do
      "" ->
        {"", ""}

      text ->
        case split(text, @caption_chars) do
          [caption] -> {caption, ""}
          [caption | rest] -> {caption, Enum.join(rest)}
        end
    end
  end

  @doc """
  One interactive message for the pending actions of a reply presentation.

  Up to three actions become reply buttons, and more become one list section.
  SignalsGateway allows at most eight choices, which stays inside the Cloud API
  limit of ten list rows.

  Every title starts with its ordinal, because the Cloud API refuses a whole
  interactive message whose titles repeat, and two long choices cut to the title
  limit read the same. The ordinal also tells the user which choice a short
  title stands for: long button labels continue under the body text, and a cut
  row title keeps its full text in the row description.
  """
  @spec action_message(map(), String.t(), term()) :: map() | nil
  def action_message(presentation, actor_event_id, fallback_text)
      when is_map(presentation) and is_binary(actor_event_id) do
    case ReplyPresentation.normalize(presentation) do
      %{"interaction_status" => "pending", "actions" => actions} = normalized
      when is_list(actions) ->
        body = body_text(normalized, fallback_text)

        actions
        |> Enum.with_index()
        |> Enum.flat_map(&option(&1, actor_event_id))
        |> Enum.with_index(1)
        |> Enum.map(fn {option, ordinal} -> Map.put(option, :ordinal, ordinal) end)
        |> interactive(body)

      _presentation ->
        nil
    end
  end

  def action_message(_presentation, _actor_event_id, _fallback_text), do: nil

  defp interactive([], _body), do: nil

  defp interactive(options, body) when length(options) <= @reply_buttons do
    buttons =
      Enum.map(options, fn option ->
        %{
          "type" => "reply",
          "reply" => %{"id" => option.token, "title" => numbered(option, @button_title_chars)}
        }
      end)

    # A button title holds 20 characters and carries no description, so a label
    # the title cannot hold continues under the body text against its ordinal.
    body =
      case Enum.filter(options, &cut?(&1, @button_title_chars)) do
        [] -> body
        _cut -> body <> "\n\n" <> Enum.map_join(options, "\n", &numbered(&1, @body_chars))
      end

    build(
      %{
        "type" => "button",
        "body" => %{"text" => truncate(body, @body_chars)},
        "action" => %{"buttons" => buttons}
      },
      Enum.map(buttons, &get_in(&1, ["reply", "title"]))
    )
  end

  defp interactive(options, body) do
    rows =
      Enum.map(options, fn option ->
        %{"id" => option.token, "title" => numbered(option, @row_title_chars)}
        |> put_description(option)
      end)

    build(
      %{
        "type" => "list",
        "body" => %{"text" => truncate(body, @body_chars)},
        "action" => %{
          "button" => list_button_label(),
          "sections" => [%{"rows" => rows}]
        }
      },
      Enum.map(rows, & &1["title"])
    )
  end

  # Ordinals make the titles unique for the at most eight choices the gateway
  # allows, so this guard should never fire. It states the provider contract:
  # Meta rejects the whole message when two titles repeat, and a refused message
  # would make an already sent text chunk an uncertain reply.
  defp build(interactive, titles) do
    if length(Enum.uniq(titles)) == length(titles) do
      %{"type" => "interactive", "interactive" => interactive}
    else
      Logging.warning(
        "whatsapp_adapter.presentation.duplicate_titles",
        "WhatsApp interactive choices were dropped because their titles repeat",
        %{title_count: length(titles)}
      )

      nil
    end
  end

  defp put_description(row, option) do
    if cut?(option, @row_title_chars),
      do: Map.put(row, "description", truncate(option.label, @row_description_chars)),
      else: row
  end

  defp numbered(%{ordinal: ordinal, label: label}, limit),
    do: truncate("#{ordinal}. #{label}", limit)

  defp cut?(%{ordinal: ordinal, label: label} = option, limit),
    do: numbered(option, limit) != String.trim("#{ordinal}. #{label}")

  defp option({%{"type" => "button", "disabled" => true}, _index}, _event_id), do: []

  defp option({%{"type" => "button"} = action, index}, event_id) do
    with label when is_binary(label) and label != "" <- action["label"],
         {:ok, token} <-
           ReplyActionToken.encode(event_id, index, action,
             prefix: "wa1",
             max_bytes: @token_bytes,
             too_long_error: :interactive_id_too_long
           ) do
      [%{token: token, label: label}]
    else
      _invalid -> []
    end
  end

  defp option({_action, _index}, _event_id), do: []

  defp body_text(presentation, fallback_text) do
    prompt =
      case presentation["prompt"] do
        text when is_binary(text) and text != "" -> text
        _missing -> fallback_or_presentation(presentation, fallback_text)
      end

    case truncate(prompt, @body_chars) do
      "" -> I18n.t("signals_gateway.reply.needs_input")
      text -> text
    end
  end

  defp fallback_or_presentation(presentation, fallback_text) do
    case String.trim(to_string(fallback_text || "")) do
      "" -> ReplyPresentation.fallback_text(presentation)
      text -> text
    end
  end

  # The list button only opens the row list. It is a control, not the question,
  # so it carries a fixed localized label instead of a cut of the prompt.
  defp list_button_label do
    truncate(I18n.t("signals_gateway.reply.choose_option"), @list_button_chars)
  end

  defp truncate(text, limit) do
    case text |> to_string() |> String.trim() do
      "" -> ""
      trimmed -> trimmed |> split(limit) |> List.first()
    end
  end

  # WhatsApp counts Unicode characters. A grapheme cluster can hold several of
  # them, so the chunk closes on the character count and never cuts a cluster.
  defp split(text, limit) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], [], 0}, fn grapheme, {done, current, count} ->
      size = grapheme |> String.to_charlist() |> length()

      if current != [] and count + size > limit do
        {[Enum.reverse(current) | done], [grapheme], size}
      else
        {done, [grapheme | current], count + size}
      end
    end)
    |> then(fn {done, current, _count} ->
      [Enum.reverse(current) | done]
      |> Enum.reverse()
      |> Enum.map(&IO.iodata_to_binary/1)
    end)
  end
end
