defmodule Ankole.Plugins.Microsoft365Adapter.AdaptiveCard do
  @moduledoc false

  alias Ankole.I18n
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Conversations.Delivery.ReplyPresentation

  @content_type "application/vnd.microsoft.card.adaptive"
  # Action.Submit merges input values into its own data, so input IDs carry a
  # prefix that cannot collide with the `v` and `value` envelope keys.
  @input_prefix "input."

  @spec action_envelope_version() :: String.t()
  def action_envelope_version, do: ReplyPresentation.action_protocol()

  @doc "Returns the form values that an Action.Submit activity carries, keyed by field ID."
  @spec submitted_inputs(map()) :: map()
  def submitted_inputs(value) when is_map(value) do
    for {@input_prefix <> id, input} <- value, into: %{}, do: {id, input}
  end

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

  @spec render_reply_presentation(map() | nil, String.t() | nil) :: {:ok, map()} | :none
  def render_reply_presentation(presentation, source_signal_id)
      when is_map(presentation) and is_binary(source_signal_id) and source_signal_id != "" do
    normalized = ReplyPresentation.normalize(presentation)

    locked? =
      normalized["state"] != "awaiting_input" or
        normalized["interaction_status"] in ["answered", "superseded"]

    actions =
      normalized
      |> Map.get("actions", [])
      |> Enum.flat_map(&presentation_submit_action(&1, source_signal_id))

    if locked? or actions == [] do
      :none
    else
      answer = MapHelpers.optional_text(normalized, "answer")
      prompt = MapHelpers.optional_text(normalized, "prompt")

      body =
        []
        |> add_body(answer)
        |> then(fn blocks ->
          if is_binary(prompt) and prompt != answer, do: add_body(blocks, prompt), else: blocks
        end)
        |> Kernel.++(Enum.flat_map(normalized["actions"], &form_inputs/1))

      {:ok, card(body, actions)}
    end
  end

  def render_reply_presentation(_presentation, _source_signal_id), do: :none

  defp presentation_submit_action(%{"type" => "button"} = action, source_signal_id) do
    if action["disabled"] == true do
      []
    else
      case ReplyPresentation.callback_value(source_signal_id, action) do
        {:ok, callback_value} ->
          [
            %{
              "type" => "Action.Submit",
              "title" => truncate(to_string(action["label"] || action["selected_option_id"]), 75),
              "data" => %{
                "v" => ReplyPresentation.action_protocol(),
                "value" => callback_value
              }
            }
          ]

        {:error, _} ->
          []
      end
    end
  end

  defp presentation_submit_action(%{"type" => "form"} = action, source_signal_id) do
    with true <- ReplyPresentation.typed_form?(action) and action["disabled"] != true,
         {:ok, callback_value} <- ReplyPresentation.callback_value(source_signal_id, action) do
      [
        %{
          "type" => "Action.Submit",
          "title" => truncate(action["label"], 75),
          "style" => "positive",
          "data" => %{"v" => ReplyPresentation.action_protocol(), "value" => callback_value}
        }
      ]
    else
      _disabled_or_invalid -> []
    end
  end

  defp presentation_submit_action(%{"type" => "link", "url" => url} = action, _source_signal_id) do
    if action["disabled"] == true,
      do: [],
      else: [
        %{"type" => "Action.OpenUrl", "title" => truncate(action["label"], 75), "url" => url}
      ]
  end

  defp presentation_submit_action(_action, _source_signal_id), do: []

  # Inputs validate on the client before Action.Submit sends them; the server
  # validates again with the authoritative form.
  defp form_inputs(%{"type" => "form", "fields" => fields} = action) do
    if ReplyPresentation.typed_form?(action) and action["disabled"] != true,
      do: Enum.flat_map(fields, &field_input/1),
      else: []
  end

  defp form_inputs(_action), do: []

  defp field_input(field) do
    input =
      %{"id" => @input_prefix <> field["id"], "label" => field["label"]}
      |> Map.merge(input_element(field))
      |> MapHelpers.compact_map()

    case field["help"] do
      nil -> [input]
      help -> [input, subtle_text_block(help)]
    end
  end

  defp input_element(%{"type" => "text"} = field) do
    %{
      "type" => "Input.Text",
      "isRequired" => field["required"],
      "maxLength" => field["max_length"],
      "isMultiline" => field["multiline"],
      "value" => field["default"]
    }
  end

  defp input_element(%{"type" => "number"} = field) do
    %{
      "type" => "Input.Number",
      "isRequired" => field["required"],
      "min" => field["min"],
      "max" => field["max"],
      "value" => field["default"]
    }
  end

  defp input_element(%{"type" => "date"} = field) do
    %{
      "type" => "Input.Date",
      "isRequired" => field["required"],
      "min" => field["min"],
      "max" => field["max"],
      "value" => field["default"]
    }
  end

  defp input_element(%{"type" => "select"} = field) do
    %{
      "type" => "Input.ChoiceSet",
      "style" => "compact",
      "isRequired" => field["required"],
      "choices" => choices(field["options"]),
      "value" => field["default"]
    }
  end

  defp input_element(%{"type" => "multi_select"} = field) do
    %{
      "type" => "Input.ChoiceSet",
      "style" => "expanded",
      "isMultiSelect" => true,
      "isRequired" => field["required"],
      "choices" => choices(field["options"]),
      "value" => if(is_list(field["default"]), do: Enum.join(field["default"], ","))
    }
  end

  # A boolean is a Yes/No choice that starts empty, so `isRequired` means the
  # user actually chose.
  defp input_element(%{"type" => "boolean"} = field) do
    %{
      "type" => "Input.ChoiceSet",
      "style" => "compact",
      "isRequired" => field["required"],
      "choices" => [
        %{"title" => I18n.t("conversations.delivery.clarify.yes"), "value" => "true"},
        %{"title" => I18n.t("conversations.delivery.clarify.no"), "value" => "false"}
      ],
      "value" => if(is_boolean(field["default"]), do: to_string(field["default"]))
    }
  end

  defp choices(options),
    do: Enum.map(options || [], &%{"title" => &1["label"], "value" => &1["value"]})

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
        "data" => %{"v" => ReplyPresentation.action_protocol(), "value" => value}
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
