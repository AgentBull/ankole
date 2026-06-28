defmodule Ankole.Plugins.LarkAdapter.Card do
  @moduledoc """
  Rendering for provider-native and portable Lark card outbox payloads.
  """

  @action_value_version "ankole.interactive_output.action.v1"

  @doc """
  Selects the best card payload shape and renders portable interaction output.
  """
  @spec render(map()) :: {:ok, map()} | {:error, term()}
  def render(payload) when is_map(payload) do
    cond do
      is_map(control_notice_payload(payload)) ->
        {:ok, compact_notice_card(notice_text(control_notice_payload(payload)), false)}

      is_map(progress_notice_payload(payload)) ->
        progress = progress_notice_payload(payload)
        {:ok, compact_notice_card(notice_text(progress), progress_divider?(progress))}

      is_map(payload["card"]) ->
        {:ok, payload["card"]}

      is_map(payload["lark_native_card"]) ->
        {:ok, payload["lark_native_card"]}

      is_map(payload["interactive_output"]) ->
        {:ok, portable_card(payload["interactive_output"])}

      true ->
        {:error, :missing_card_payload}
    end
  end

  @doc """
  Encodes a rendered card into the JSON string expected by Lark message APIs.
  """
  @spec message_content(map()) :: String.t()
  def message_content(card) when is_map(card) do
    Ankole.JSON.encode!(card)
  end

  @doc """
  Encodes plain text into the JSON string expected by Lark text messages.
  """
  @spec text_content(String.t()) :: String.t()
  def text_content(text), do: Ankole.JSON.encode!(%{text: text})

  @doc """
  Encodes a compact Lark system divider content body.
  """
  @spec system_divider_content(String.t(), map() | nil) :: String.t()
  def system_divider_content(text, i18n \\ nil) do
    divider_text =
      %{"text" => text}
      |> maybe_put("i18n_text", i18n)

    Ankole.JSON.encode!(%{
      "type" => "divider",
      "params" => %{"divider_text" => divider_text},
      "options" => %{"need_rollup" => true}
    })
  end

  defp portable_card(output) do
    title = text_field(output, "title")

    body =
      text_field(output, "body") || text_field(output, "text") ||
        text_field(output, "fallback_visible_text")

    facts = list_field(output, "facts")
    choices = list_field(output, "choices")
    state = text_field(output, "state")

    %{
      "schema" => "2.0",
      "config" => %{"update_multi" => true},
      "header" => header(title),
      "body" => %{
        "elements" =>
          []
          |> maybe_append(markdown_element(body))
          |> append_all(fact_elements(facts))
          |> append_all(choice_elements(output, choices))
          |> maybe_append(state_element(state, output))
      }
    }
  end

  defp header(nil), do: nil
  defp header(title), do: %{"title" => %{"tag" => "plain_text", "content" => title}}

  defp markdown_element(nil), do: nil
  defp markdown_element(text), do: %{"tag" => "markdown", "content" => escape_markdown(text)}

  defp state_element(nil, _output), do: nil

  defp state_element("answered", output) do
    case text_field(output, "response") do
      nil -> %{"tag" => "markdown", "content" => "Answered"}
      response -> %{"tag" => "markdown", "content" => "Answered: #{escape_markdown(response)}"}
    end
  end

  defp state_element("expired", _output), do: %{"tag" => "markdown", "content" => "Expired"}
  defp state_element("cancelled", _output), do: %{"tag" => "markdown", "content" => "Cancelled"}
  defp state_element("superseded", _output), do: %{"tag" => "markdown", "content" => "Superseded"}

  defp state_element(state, _output),
    do: %{"tag" => "markdown", "content" => escape_markdown(state)}

  defp control_notice_payload(%{"control_notice" => notice}) when is_map(notice), do: notice

  defp control_notice_payload(%{"kind" => "control_notice", "body" => body}) when is_map(body),
    do: body

  defp control_notice_payload(%{"type" => "control_notice", "body" => body}) when is_map(body),
    do: body

  defp control_notice_payload(%{"kind" => "control_notice"} = notice), do: notice
  defp control_notice_payload(%{"type" => "control_notice"} = notice), do: notice
  defp control_notice_payload(_payload), do: nil

  defp progress_notice_payload(%{"progress_notice" => notice}) when is_map(notice), do: notice

  defp progress_notice_payload(%{"kind" => "progress_notice", "body" => body}) when is_map(body),
    do: body

  defp progress_notice_payload(%{"type" => "progress_notice", "body" => body}) when is_map(body),
    do: body

  defp progress_notice_payload(%{"kind" => "progress_notice"} = notice), do: notice
  defp progress_notice_payload(%{"type" => "progress_notice"} = notice), do: notice
  defp progress_notice_payload(_payload), do: nil

  defp notice_text(notice) do
    text_field(notice, "text") ||
      text_field(notice, "short_text") ||
      text_field(notice, "fallback_visible_text") ||
      "Notice"
  end

  defp compact_notice_card(text, divider?) do
    %{
      "schema" => "2.0",
      "config" => %{"update_multi" => true},
      "body" => %{
        "direction" => "vertical",
        "horizontal_spacing" => "8px",
        "vertical_spacing" => "8px",
        "horizontal_align" => "left",
        "vertical_align" => "top",
        "padding" => "12px 12px 12px 12px",
        "elements" => compact_notice_elements(text, divider?)
      }
    }
  end

  defp compact_notice_elements(text, true), do: [compact_hr(), compact_text(text)]
  defp compact_notice_elements(text, false), do: [compact_text(text)]

  defp compact_hr, do: %{"tag" => "hr", "margin" => "0px 0px 0px 0px"}

  defp compact_text(text) do
    %{
      "tag" => "div",
      "text" => %{
        "tag" => "plain_text",
        "content" => text,
        "text_size" => "notation",
        "text_align" => "left",
        "text_color" => "grey"
      },
      "margin" => "0px 0px 0px 0px"
    }
  end

  defp progress_divider?(notice), do: fetch_value(notice, "show_divider") == true

  defp fact_elements(facts) do
    Enum.map(facts, fn fact ->
      label = text_field(fact, "label") || ""
      value = text_field(fact, "value") || ""

      %{
        "tag" => "markdown",
        "content" => "**#{escape_markdown(label)}** #{escape_markdown(value)}"
      }
    end)
  end

  defp choice_elements(output, choices) do
    interaction_id = text_field(output, "interaction_id")
    control_id = text_field(output, "control_id") || "choice"
    version = integer_field(output, "version") || 1
    locked? = text_field(output, "state") in ["answered", "expired", "cancelled", "superseded"]
    selected_id = text_field(output, "selected_option_id")

    # The value payload keeps the portable interaction ids inside the provider
    # card action. It lets inbound card events reconstruct the original control.
    Enum.map(choices, fn choice ->
      option_id = text_field(choice, "id") || text_field(choice, "option_id")
      label = text_field(choice, "label") || text_field(choice, "text") || option_id || "Choice"

      visible_label =
        case option_id == selected_id and not is_nil(selected_id) do
          true -> "#{label} (selected)"
          false -> label
        end

      %{
        "tag" => "button",
        "text" => %{"tag" => "plain_text", "content" => visible_label},
        "disabled" => locked?,
        "value" => %{
          "version" => @action_value_version,
          "interactionVersion" => version,
          "interactionId" => interaction_id,
          "controlId" => control_id,
          "selectedOptionId" => option_id,
          "optionValue" => fetch_value(choice, "value") || option_id
        }
      }
    end)
  end

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, item), do: list ++ [item]

  defp append_all(list, values), do: list ++ values

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp escape_markdown(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("*", "\\*")
    |> String.replace("_", "\\_")
    |> String.replace("`", "\\`")
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
  end

  defp list_field(map, key) do
    case fetch_value(map, key) do
      values when is_list(values) -> values
      _value -> []
    end
  end

  defp text_field(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp integer_field(map, key) do
    case fetch_value(map, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp fetch_value(map, key) when is_map(map) do
    atom_key = atom_key(key)

    # Portable payloads may come from JSON or local tests. Existing atom keys are
    # accepted, but new atoms are never created from provider-controlled data.
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)
      true -> nil
    end
  end

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
