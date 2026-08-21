defmodule Ankole.Plugins.TelegramAdapter.Presentation do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.Plugins.TelegramAdapter.ActionToken
  alias Ankole.SignalsGateway.ReplyPresentation

  @message_chars 4_000
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
             {:ok, token} <- ActionToken.encode(event_id, index, action) do
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
    |> String.graphemes()
    |> Enum.chunk_every(@message_chars)
    |> Enum.map(&Enum.join/1)
    |> case do
      [] -> [I18n.t("signals_gateway.reply.no_content")]
      values -> values
    end
  end
end
