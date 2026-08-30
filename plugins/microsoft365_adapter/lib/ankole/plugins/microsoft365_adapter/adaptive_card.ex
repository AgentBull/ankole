defmodule Ankole.Plugins.Microsoft365Adapter.AdaptiveCard do
  @moduledoc false

  alias Ankole.Plugins.MapHelpers

  @content_type "application/vnd.microsoft.card.adaptive"
  @action_envelope_version "ankole.interactive_output.action.v1"

  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @spec action_envelope_version() :: String.t()
  def action_envelope_version, do: @action_envelope_version

  @spec render(map()) :: {:ok, map()} | {:error, :missing_card_payload}
  def render(payload) when is_map(payload) do
    cond do
      notice = Map.get(payload, "control_notice") ->
        {:ok, card([subtle_text_block(notice_text(notice))])}

      notice = Map.get(payload, "progress_notice") ->
        {:ok, card([subtle_text_block(notice_text(notice))])}

      is_map(Map.get(payload, "teams_native_card")) ->
        {:ok, payload["teams_native_card"]}

      is_map(Map.get(payload, "interactive_output")) ->
        {:ok, render_interactive(payload["interactive_output"])}

      true ->
        {:error, :missing_card_payload}
    end
  end

  @spec attachment(map()) :: map()
  def attachment(card_content),
    do: %{"contentType" => @content_type, "content" => card_content}

  defp render_interactive(output) do
    body =
      []
      |> add_title(MapHelpers.optional_text(output, "title"))
      |> add_body(body_text(output))
      |> add_facts(MapHelpers.fetch_list(output, "facts"))
      |> add_state(MapHelpers.optional_text(output, "state"))

    card(body, choice_actions(MapHelpers.fetch_list(output, "choices")))
  end

  defp card(body, actions \\ []) do
    %{
      "type" => "AdaptiveCard",
      "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json",
      "version" => "1.4",
      "body" => body
    }
    |> then(fn card ->
      if actions == [], do: card, else: Map.put(card, "actions", actions)
    end)
  end

  defp add_title(body, nil), do: body

  defp add_title(body, title) do
    body ++
      [
        %{
          "type" => "TextBlock",
          "text" => truncate(title, 150),
          "size" => "Large",
          "weight" => "Bolder",
          "wrap" => true
        }
      ]
  end

  defp body_text(output) do
    MapHelpers.optional_text(output, "body") ||
      MapHelpers.optional_text(output, "text") ||
      MapHelpers.optional_text(output, "fallback_visible_text")
  end

  defp add_body(body, nil), do: body

  defp add_body(body, text),
    do: body ++ [%{"type" => "TextBlock", "text" => text, "wrap" => true}]

  defp add_facts(body, []), do: body

  defp add_facts(body, facts) do
    body ++
      [
        %{
          "type" => "FactSet",
          "facts" =>
            Enum.map(facts, fn fact ->
              %{
                "title" => to_string(Map.get(fact, "label", "")),
                "value" => to_string(Map.get(fact, "value", ""))
              }
            end)
        }
      ]
  end

  defp add_state(body, nil), do: body
  defp add_state(body, state), do: body ++ [subtle_text_block(state)]

  defp choice_actions(choices) do
    Enum.map(choices, fn choice ->
      value = to_string(Map.get(choice, "value", ""))

      %{
        "type" => "Action.Submit",
        "title" => truncate(to_string(Map.get(choice, "label", value)), 75),
        "data" => %{"v" => @action_envelope_version, "value" => value}
      }
    end)
  end

  defp subtle_text_block(text) do
    %{
      "type" => "TextBlock",
      "text" => notice_text(text),
      "wrap" => true,
      "isSubtle" => true,
      "size" => "Small"
    }
  end

  defp notice_text(notice) when is_binary(notice), do: notice

  defp notice_text(notice) when is_map(notice),
    do: Map.get(notice, "text") || Map.get(notice, "message") || ""

  defp notice_text(_notice), do: ""

  defp truncate(text, size), do: String.slice(text, 0, size)
end
