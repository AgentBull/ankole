defmodule Ankole.Plugins.TelegramAdapter.Presentation do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.SignalsGateway.ReplyActionToken
  alias Ankole.SignalsGateway.ReplyPresentation

  @message_utf16_units 4_000
  @button_chars 64

  @spec render(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def render(presentation, actor_event_id)
      when is_map(presentation) and is_binary(actor_event_id) do
    presentation = ReplyPresentation.normalize(presentation)
    text = ReplyPresentation.fallback_text(presentation)
    keyboard = inline_keyboard(presentation, actor_event_id)

    chunks(text)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %{"text" => chunk}
      |> maybe_put_keyboard(if(index == 0, do: keyboard, else: []))
    end)
    |> then(&{:ok, &1})
  end

  def render(_presentation, _actor_event_id), do: {:error, :invalid_telegram_presentation}

  @spec card(map(), String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def card(%{"reply_presentation" => presentation}, _fallback, actor_event_id)
      when is_map(presentation) and is_binary(actor_event_id),
      do: render(presentation, actor_event_id)

  def card(_payload, fallback, _actor_event_id) do
    {:ok, Enum.map(chunks(fallback), &%{"text" => &1})}
  end

  defp inline_keyboard(%{"interaction_status" => "pending", "actions" => actions}, event_id)
       when is_list(actions) do
    actions
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"type" => "button", "disabled" => disabled}, _index}
      when disabled == true ->
        []

      {%{"type" => "button"} = action, index} ->
        with label when is_binary(label) <- action["label"],
             {:ok, token} <-
               ReplyActionToken.encode(event_id, index, action,
                 prefix: "tg1",
                 max_bytes: 64,
                 too_long_error: :callback_token_too_long
               ) do
          [%{"text" => String.slice(label, 0, @button_chars), "callback_data" => token}]
        else
          _invalid -> []
        end

      {_action, _index} ->
        []
    end)
    |> Enum.chunk_every(2)
  end

  defp inline_keyboard(_presentation, _event_id), do: []

  defp maybe_put_keyboard(message, []), do: message

  defp maybe_put_keyboard(message, rows),
    do: Map.put(message, "reply_markup", %{"inline_keyboard" => rows})

  @doc false
  def chunks(value) do
    value
    |> to_string()
    |> message_chunks()
    |> case do
      [] -> [I18n.t("signals_gateway.reply.no_content")]
      values -> values
    end
  end

  defp message_chunks(text) do
    {chunks, current, _units} =
      text
      |> String.graphemes()
      |> Enum.flat_map(fn grapheme ->
        if utf16_units(grapheme) > @message_utf16_units,
          do: String.codepoints(grapheme),
          else: [grapheme]
      end)
      |> Enum.reduce({[], [], 0}, fn segment, {chunks, current, units} ->
        segment_units = utf16_units(segment)

        if units + segment_units <= @message_utf16_units do
          {chunks, [segment | current], units + segment_units}
        else
          {[Enum.join(Enum.reverse(current)) | chunks], [segment], segment_units}
        end
      end)

    chunks =
      case current do
        [] -> chunks
        current -> [Enum.join(Enum.reverse(current)) | chunks]
      end

    Enum.reverse(chunks)
  end

  defp utf16_units(text) do
    Enum.reduce(String.to_charlist(text), 0, fn codepoint, units ->
      units + if(codepoint > 0xFFFF, do: 2, else: 1)
    end)
  end
end
