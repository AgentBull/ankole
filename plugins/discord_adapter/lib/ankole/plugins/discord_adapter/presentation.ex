defmodule Ankole.Plugins.DiscordAdapter.Presentation do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.SignalsGateway.ReplyActionToken
  alias Ankole.SignalsGateway.ReplyPresentation

  @message_utf16_units 2_000
  @button_chars 80
  @buttons_per_row 5
  @rows 5

  @action_row 1
  @button 2
  @primary_style 1

  @spec render(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def render(presentation, actor_event_id)
      when is_map(presentation) and is_binary(actor_event_id) do
    presentation = ReplyPresentation.normalize(presentation)
    text = ReplyPresentation.fallback_text(presentation)
    components = components(presentation, actor_event_id)

    chunks(text)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %{"content" => chunk, "components" => if(index == 0, do: components, else: [])}
    end)
    |> then(&{:ok, &1})
  end

  def render(_presentation, _actor_event_id), do: {:error, :invalid_discord_presentation}

  @spec card(map(), String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def card(%{"reply_presentation" => presentation}, _fallback, actor_event_id)
      when is_map(presentation) and is_binary(actor_event_id),
      do: render(presentation, actor_event_id)

  def card(_payload, fallback, _actor_event_id) do
    {:ok, Enum.map(chunks(fallback), &%{"content" => &1, "components" => []})}
  end

  # Discord carries buttons in action rows of at most five buttons, and one
  # message carries at most five rows. Actions past that budget are dropped
  # rather than sent in a request Discord would reject whole.
  defp components(%{"interaction_status" => "pending", "actions" => actions}, event_id)
       when is_list(actions) do
    actions
    |> Enum.with_index()
    |> Enum.flat_map(&button(&1, event_id))
    |> Enum.take(@buttons_per_row * @rows)
    |> Enum.chunk_every(@buttons_per_row)
    |> Enum.map(&%{"type" => @action_row, "components" => &1})
  end

  defp components(_presentation, _event_id), do: []

  defp button({%{"type" => "button", "disabled" => true}, _index}, _event_id), do: []

  defp button({%{"type" => "button"} = action, index}, event_id) do
    with label when is_binary(label) <- action["label"],
         {:ok, custom_id} <-
           ReplyActionToken.encode(event_id, index, action,
             prefix: "dc1",
             max_bytes: 100,
             too_long_error: :custom_id_too_long
           ) do
      [
        %{
          "type" => @button,
          "style" => @primary_style,
          "label" => String.slice(label, 0, @button_chars),
          "custom_id" => custom_id
        }
      ]
    else
      _invalid -> []
    end
  end

  defp button({_action, _index}, _event_id), do: []

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
