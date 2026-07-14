defmodule Ankole.SignalsGateway.ClarifyPrompt do
  @moduledoc """
  Extracts a turn-ending `clarify` tool result into portable interactive output.
  """

  alias Ankole.Ecto.JSONPayload
  alias Ankole.SignalsGateway.ToolOutput

  @tool_name "clarify"

  @spec from_response_items(term()) :: {:ok, map() | nil} | {:error, term()}
  def from_response_items(items) when is_list(items) do
    call_ids = tool_call_ids(items)

    items
    |> Enum.reduce_while({:ok, nil}, fn
      %{"type" => "function_call_output", "call_id" => call_id, "output" => output}, {:ok, prompt}
      when is_binary(call_id) ->
        if MapSet.member?(call_ids, call_id) do
          case normalize_output(ToolOutput.decode(output), call_id) do
            {:ok, normalized} -> {:cont, {:ok, normalized}}
            :ignore -> {:cont, {:ok, prompt}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, prompt}}
        end

      _item, acc ->
        {:cont, acc}
    end)
  end

  def from_response_items(_items), do: {:ok, nil}

  defp tool_call_ids(items) do
    Enum.reduce(items, MapSet.new(), fn
      %{"type" => "function_call", "name" => @tool_name, "call_id" => call_id}, acc
      when is_binary(call_id) ->
        MapSet.put(acc, call_id)

      _item, acc ->
        acc
    end)
  end

  defp normalize_output(%{"tool" => @tool_name} = output, call_id) do
    with {:ok, question} <- required_text(output, "question"),
         {:ok, choices} <- normalize_choices(Map.get(output, "choices", [])) do
      fallback = fallback_text(question, choices)

      {:ok,
       %{
         "fallback_visible_text" => fallback,
         "interactive_output" => %{
           "title" => "Clarification",
           "body" => question,
           "fallback_visible_text" => fallback,
           "interaction_id" => "clarify:#{call_id}",
           "control_id" => "clarify-choice",
           "version" => 1,
           "free_input" => true,
           "free_input_hint" => "You can also reply in your own words.",
           "choices" => choices
         }
       }}
    else
      {:error, reason} -> {:error, {:invalid_clarify_output, call_id, reason}}
    end
  end

  defp normalize_output(_output, _call_id), do: :ignore

  defp normalize_choices(choices) when is_list(choices) and length(choices) <= 4 do
    choices
    |> Enum.with_index(1)
    |> Enum.map(fn {choice, index} -> normalize_choice(choice, index) end)
    |> collect_results()
  end

  defp normalize_choices(_choices), do: {:error, :choices_invalid}

  defp normalize_choice(choice, index) do
    with {:ok, choice} <- JSONPayload.normalize_map(choice),
         {:ok, label} <- required_text(choice, "label") do
      {:ok,
       %{
         "id" => "choice-#{index}",
         "label" => label,
         "value" => label
       }
       |> maybe_put("description", optional_text(choice, "description"))}
    end
  end

  defp fallback_text(question, choices) do
    options =
      choices
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {choice, index} ->
        description =
          case choice["description"] do
            text when is_binary(text) and text != "" -> " — #{text}"
            _value -> ""
          end

        "#{index}. #{choice["label"]}#{description}"
      end)

    "#{question}\n\n#{options}\n\nReply with a number or type your answer."
  end

  defp required_text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, String.trim(value)}
      _value -> {:error, {String.to_atom(key), :required}}
    end
  end

  defp optional_text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> String.trim(value)
      _value -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end
end
