defmodule Ankole.AIGateway.CompactionRetention do
  @moduledoc """
  Selects verbatim originals to replay alongside compaction summaries.

  User originals replay recent user messages inside a token budget. The pending
  clarify pair preserves one unanswered question. Client Tool Search pairs
  preserve loaded tool contracts that would otherwise leave effective history.
  """

  alias Ankole.AIGateway.CompactionRender
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ToolContract

  @clarify_tool "clarify"

  @spec collect_user_originals([map()], pos_integer()) :: {[map()], non_neg_integer()}
  def collect_user_originals(items, budget_tokens)
      when is_list(items) and is_integer(budget_tokens) and budget_tokens > 0 do
    items
    |> Enum.filter(&user_original?/1)
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn item, {selected, used} ->
      remaining = budget_tokens - used
      cost = item_cost(item)

      cond do
        remaining <= 0 ->
          {:halt, {selected, used}}

        cost <= remaining ->
          {:cont, {[item | selected], used + cost}}

        true ->
          case truncate_item(item, remaining) do
            nil -> {:halt, {selected, used}}
            truncated -> {:halt, {[truncated | selected], budget_tokens}}
          end
      end
    end)
  end

  def collect_user_originals(_items, _budget_tokens), do: {[], 0}

  @doc """
  Selects the newest still-unanswered `clarify` call/output pair.

  A clarify question ends its turn, and the answer arrives as a later user
  message. When compaction folds the question while the answer sits in the
  retained tail or the current input, the model reads an answer to an invisible
  question. This returns the newest clarify pair with no user message after it,
  so the caller can replay it verbatim; any later user message closes the
  exchange and the summary alone carries it. The pair is returned together to
  keep call/output pairing valid, and it stays unbudgeted because the clarify
  tool contract bounds the question and choices.
  """
  @spec collect_pending_clarify([map()]) :: [map()]
  def collect_pending_clarify(items) when is_list(items) do
    items
    |> Enum.reduce(nil, fn
      %{"type" => "function_call", "name" => @clarify_tool, "call_id" => call_id} = call, _pending
      when is_binary(call_id) and call_id != "" ->
        {call, call_id, nil}

      %{"type" => "function_call_output", "call_id" => call_id} = output, {call, pending_id, nil}
      when call_id == pending_id ->
        {call, pending_id, output}

      item, pending ->
        if user_original?(item), do: nil, else: pending
    end)
    |> case do
      {call, _call_id, %{} = output} -> [call, output]
      _incomplete_or_answered -> []
    end
  end

  def collect_pending_clarify(_items), do: []

  @doc """
  Selects settled client Tool Search pairs whose contracts are not in the
  surviving history.

  Selection runs newest-first and keeps a whole original pair when it adds at
  least one contract version. This preserves conflicting contracts for normal
  validation, while equal later pairs replace redundant earlier pairs.
  """
  @spec collect_client_tool_search([map()], [map()]) ::
          {:ok, [map()]} | {:error, term()}
  def collect_client_tool_search(source_items, surviving_items \\ [])

  def collect_client_tool_search(source_items, surviving_items)
      when is_list(source_items) and is_list(surviving_items) do
    with {:ok, surviving_pairs} <- client_tool_search_pairs(surviving_items),
         {:ok, source_pairs} <- client_tool_search_pairs(source_items),
         {:ok, seen_versions} <- pair_contract_versions(surviving_pairs) do
      source_pairs
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, [], seen_versions}, fn pair, {:ok, selected, seen} ->
        case tool_contract_versions(pair.output) do
          {:ok, versions} ->
            if MapSet.size(MapSet.difference(versions, seen)) > 0 do
              selected = [pair.call, pair.output | selected]
              {:cont, {:ok, selected, MapSet.union(seen, versions)}}
            else
              {:cont, {:ok, selected, seen}}
            end

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, selected, _seen} -> {:ok, selected}
        {:error, _reason} = error -> error
      end
    end
  end

  def collect_client_tool_search(_source_items, _surviving_items),
    do: {:error, :invalid_compaction_items}

  defp client_tool_search_pairs(items) do
    case ResponseItems.analyze_history(items) do
      %ResponseItems.History{error: nil, ledger: ledger} ->
        ledger
        |> ResponseItems.search_pairs()
        |> Enum.filter(&match?({:search, :client, _call_id}, &1.pair_key))
        |> Enum.reduce_while({:ok, []}, fn
          %{
            call: %{item: call},
            output: %{item: %{"tools" => tools, "status" => "completed"} = output}
          },
          {:ok, pairs}
          when is_list(tools) ->
            if ResponseItems.executable_call?(call) do
              {:cont, {:ok, [%{call: call, output: output} | pairs]}}
            else
              {:halt, {:error, {:invalid_tool_search_call, call["call_id"]}}}
            end

          %{call: %{item: call}}, _acc ->
            {:halt, {:error, {:unsettled_tool_search_call, call["call_id"]}}}
        end)
        |> case do
          {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
          {:error, _reason} = error -> error
        end

      %ResponseItems.History{error: %{reason: reason}} ->
        {:error, reason}
    end
  end

  defp pair_contract_versions(pairs) do
    Enum.reduce_while(pairs, {:ok, MapSet.new()}, fn pair, {:ok, seen} ->
      case tool_contract_versions(pair.output) do
        {:ok, versions} ->
          {:cont, {:ok, MapSet.union(seen, versions)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp tool_contract_versions(%{"tools" => tools}) do
    with {:ok, descriptors} <- ToolContract.normalize(tools, reserved_names: []) do
      {:ok,
       MapSet.new(descriptors, fn descriptor ->
         {ToolContract.identity(descriptor), ToolContract.fingerprint([descriptor])}
       end)}
    end
  end

  defp user_original?(%{"role" => "user"} = item), do: Map.get(item, "type") in [nil, "message"]
  defp user_original?(_item), do: false

  defp item_cost(%{"content" => content}) do
    text_cost = content_text_token_cost(content)

    cond do
      text_cost > 0 -> text_cost
      content_has_part?(content) -> 1
      true -> 0
    end
  end

  defp item_cost(_item), do: 0

  defp content_text_token_cost(content) when is_binary(content),
    do: CompactionRender.approx_tokens(content)

  defp content_text_token_cost(content) when is_list(content) do
    Enum.reduce(content, 0, fn
      %{"type" => type, "text" => text}, total
      when type in ["input_text", "output_text", "text"] and is_binary(text) ->
        total + CompactionRender.approx_tokens(text)

      %{"text" => text}, total when is_binary(text) ->
        total + CompactionRender.approx_tokens(text)

      _part, total ->
        total
    end)
  end

  defp content_text_token_cost(_content), do: 0

  defp content_has_part?(content) when is_binary(content), do: content != ""
  defp content_has_part?(content) when is_list(content), do: content != []
  defp content_has_part?(_content), do: false

  defp truncate_item(item, remaining) when remaining > 0 do
    case Map.get(item, "content") do
      content when is_binary(content) ->
        truncated = CompactionRender.truncate_text(content, remaining)
        if truncated == "", do: nil, else: Map.put(item, "content", truncated)

      content when is_list(content) ->
        {parts, _remaining, kept_text?} =
          Enum.reduce(content, {[], remaining, false}, fn part, {parts, rem, kept_text?} ->
            case text_part(part) do
              {:ok, text} when rem > 0 ->
                cost = CompactionRender.approx_tokens(text)

                if cost <= rem do
                  {[part | parts], rem - cost, true}
                else
                  truncated_text = CompactionRender.truncate_text(text, rem)
                  {[put_text_part(part, truncated_text) | parts], 0, true}
                end

              {:ok, _text} ->
                {parts, rem, kept_text?}

              :not_text ->
                {[part | parts], rem, kept_text?}
            end
          end)

        parts = Enum.reverse(parts)

        if parts == [] or not kept_text? do
          nil
        else
          Map.put(item, "content", parts)
        end

      _content ->
        nil
    end
  end

  defp truncate_item(_item, _remaining), do: nil

  defp text_part(%{"type" => type, "text" => text})
       when type in ["input_text", "output_text", "text"] and is_binary(text),
       do: {:ok, text}

  defp text_part(%{"text" => text}) when is_binary(text), do: {:ok, text}
  defp text_part(_part), do: :not_text

  defp put_text_part(part, text), do: Map.put(part, "text", text)
end
