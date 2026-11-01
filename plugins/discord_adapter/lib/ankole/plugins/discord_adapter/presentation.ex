defmodule Ankole.Plugins.DiscordAdapter.Presentation do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.Plugins.UTF16Text
  alias Ankole.Conversations.Delivery.ActionToken
  alias Ankole.Conversations.Delivery.ReplyPresentation

  @message_utf16_units 2_000
  @button_chars 80
  @buttons_per_row 5
  @rows 5

  @action_row 1
  @button 2
  @primary_style 1

  @spec render(map(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def render(presentation, signal_id)
      when is_map(presentation) and is_binary(signal_id) do
    presentation = ReplyPresentation.normalize(presentation)

    text =
      presentation
      |> ReplyPresentation.fallback_text()
      |> Ankole.Kernel.repair_generated_markdown()

    components = components(presentation, signal_id)

    chunks(text)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %{"content" => chunk, "components" => if(index == 0, do: components, else: [])}
    end)
    |> then(&{:ok, &1})
  end

  def render(_presentation, _signal_id), do: {:error, :invalid_discord_presentation}

  @spec card(map(), String.t(), String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def card(%{"reply_presentation" => presentation}, _fallback, signal_id)
      when is_map(presentation) and is_binary(signal_id),
      do: render(presentation, signal_id)

  def card(_payload, fallback, _signal_id) do
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
           ActionToken.encode(event_id, index, action,
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
    case UTF16Text.chunks(to_string(value), @message_utf16_units) do
      [] -> [I18n.t("conversations.delivery.reply.no_content")]
      values -> values
    end
  end
end
