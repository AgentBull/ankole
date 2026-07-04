defmodule Ankole.AIGateway.Compaction do
  @moduledoc """
  AIGateway-owned automatic history compaction.

  The token estimate is intentionally heuristic: characters / 4 plus a small
  per-item overhead. That keeps v1 dependency-free while still making overflow
  decisions proportional to the provider-facing prompt size.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.AIGateway.CompactionPrompt
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.AIGateway.Schemas.Message

  @config_key "ai_gateway.compaction"
  @default_threshold_percent 0.50
  @default_max_threshold_tokens 120_000
  @default_context_length 256_000
  @minimum_context_length 64_000
  @small_context_trigger_ratio 0.85
  @default_tail_rows 2
  @per_item_overhead_tokens 12
  @summarizer_max_output_tokens 2_048
  @opaque_ref_keys ~w(agent_computer_path blob_ref content_type file_id file_url filename id image_url media_type mime_type name path provider_file_id provider_ref provider_uri storage_ref uri url)
  @max_ref_chars 512

  @type result :: %{
          history: [Message.t()],
          previous_response_id: binary() | nil,
          compaction: Message.t() | nil,
          run_metadata: map()
        }

  @default_config %{
    "threshold" => @default_threshold_percent,
    "max_threshold_tokens" => @default_max_threshold_tokens,
    "tail_rows" => @default_tail_rows
  }

  @type threshold_spec :: %{
          tokens: pos_integer(),
          context_length: pos_integer(),
          effective_context_length: pos_integer(),
          threshold: float(),
          max_threshold_tokens: pos_integer(),
          max_output_tokens: pos_integer() | nil
        }

  @spec config_definition() :: Definition.t()
  def config_definition do
    AppConfigure.define(
      key: @config_key,
      encrypted: false,
      schema: config_schema(),
      default_value: @default_config,
      description:
        "AIGateway automatic history compaction settings. `threshold` is a ratio of the model input context; `max_threshold_tokens` caps that computed trigger."
    )
  end

  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([config_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @config_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_config(map()) :: {:ok, map()} | {:error, term()}
  def put_config(config) when is_map(config) do
    with :ok <- ensure_registered() do
      AppConfigure.put_global(config_definition(), config)
    end
  end

  @spec delete_config() :: :ok | {:error, term()}
  def delete_config do
    with :ok <- ensure_registered() do
      AppConfigure.delete_global(config_definition())
    end
  end

  @spec threshold_spec(map(), map()) :: threshold_spec()
  def threshold_spec(runtime \\ %{}, request \\ %{}) do
    config = config()
    context_length = context_length(runtime)
    threshold_percent = Map.get(config, "threshold", @default_threshold_percent)
    max_threshold_tokens = Map.get(config, "max_threshold_tokens", @default_max_threshold_tokens)
    max_output_tokens = max_output_tokens(request)

    {computed_tokens, effective_context_length} =
      compute_threshold_tokens(context_length, threshold_percent, max_output_tokens)

    %{
      tokens: min(computed_tokens, max_threshold_tokens),
      context_length: context_length,
      effective_context_length: effective_context_length,
      threshold: threshold_percent,
      max_threshold_tokens: max_threshold_tokens,
      max_output_tokens: max_output_tokens
    }
  end

  @spec token_threshold(map(), map()) :: pos_integer()
  def token_threshold(runtime \\ %{}, request \\ %{}) do
    runtime
    |> threshold_spec(request)
    |> Map.fetch!(:tokens)
  end

  @spec compute_token_threshold(pos_integer(), number(), pos_integer() | nil) :: pos_integer()
  def compute_token_threshold(context_length, threshold_percent, max_output_tokens \\ nil) do
    {tokens, _effective_context_length} =
      compute_threshold_tokens(context_length, threshold_percent, max_output_tokens)

    tokens
  end

  @spec maybe_compact_history(String.t(), binary(), [Message.t()], [map()], map(), map()) ::
          {:ok, result()} | {:error, term()}
  def maybe_compact_history(
        agent_uid,
        conversation_id,
        history,
        current_input,
        request,
        runtime \\ %{}
      )
      when is_list(history) and is_list(current_input) and is_map(request) do
    total_tokens = estimate_tokens(messages_to_items(history) ++ current_input)
    threshold = threshold_spec(runtime, request)

    if total_tokens <= threshold.tokens do
      {:ok, unchanged(history, request)}
    else
      compact_history(
        agent_uid,
        conversation_id,
        history,
        current_input,
        request,
        total_tokens,
        threshold
      )
    end
  end

  @doc """
  Forces one manual compaction for a conversation's current visible chain.

  This is the control-plane `/compress` path. It reuses the same candidate and
  summarizer logic as automatic compaction, but it does not depend on the
  current token estimate crossing the automatic threshold.
  """
  @spec compact_conversation(String.t(), binary(), map()) ::
          {:ok,
           %{compaction: Message.t(), previous_response_id: binary(), history: [Message.t()]}}
          | {:error, term()}
  def compact_conversation(agent_uid, conversation_id, request \\ %{}) when is_map(request) do
    history = StatefulResponses.expand_history(conversation_id)
    total_tokens = estimate_tokens(messages_to_items(history))

    with {:ok, candidate} <- compaction_candidate(history),
         {:ok, summary} <- summarize_candidate(agent_uid, candidate, request),
         {:ok, compaction} <-
           StatefulResponses.compact_history_prefix(
             agent_uid,
             "resp_#{candidate.anchor.id}",
             "resp_#{candidate.covers_until.id}",
             %{"type" => "compaction", "summary" => summary.text},
             compaction_metadata(
               summary,
               candidate,
               total_tokens,
               request_metadata(request)
               |> Map.merge(%{
                 "auto" => false,
                 "manual" => true
               })
             )
           ) do
      previous_response_id = "resp_#{compaction.id}"

      {:ok,
       %{
         compaction: compaction,
         previous_response_id: previous_response_id,
         history:
           StatefulResponses.expand_history(conversation_id,
             previous_response_id: previous_response_id
           )
       }}
    end
  end

  @spec estimate_tokens(term()) :: non_neg_integer()
  def estimate_tokens(value) when is_list(value) do
    Enum.reduce(value, 0, &(&2 + estimate_tokens(&1) + @per_item_overhead_tokens))
  end

  def estimate_tokens(value) when is_map(value) do
    value
    |> Ankole.JSON.encode!()
    |> estimate_tokens()
  end

  def estimate_tokens(value) when is_binary(value) do
    value
    |> String.length()
    |> div(4)
    |> max(1)
  end

  def estimate_tokens(nil), do: 0
  def estimate_tokens(value) when is_number(value) or is_boolean(value), do: 1
  def estimate_tokens(_value), do: 0

  defp compact_history(
         agent_uid,
         conversation_id,
         history,
         current_input,
         request,
         total_tokens,
         threshold
       ) do
    with {:ok, candidate} <- compaction_candidate(history),
         {:ok, summary} <- summarize_candidate(agent_uid, candidate, request),
         {:ok, compaction} <-
           StatefulResponses.compact_history_prefix(
             agent_uid,
             "resp_#{candidate.anchor.id}",
             "resp_#{candidate.covers_until.id}",
             %{"type" => "compaction", "summary" => summary.text},
             compaction_metadata(summary, candidate, total_tokens, %{"auto" => true})
           ) do
      previous_response_id = "resp_#{compaction.id}"

      {:ok,
       %{
         history:
           StatefulResponses.expand_history(conversation_id,
             previous_response_id: previous_response_id
           ),
         previous_response_id: previous_response_id,
         compaction: compaction,
         run_metadata: %{
           "auto_compaction" => %{
             "response_id" => previous_response_id,
             "covers_until_response_id" => "resp_#{candidate.covers_until.id}",
             "estimated_input_tokens_before" => total_tokens,
             "token_threshold" => threshold.tokens,
             "context_length" => threshold.context_length,
             "threshold" => threshold.threshold,
             "max_threshold_tokens" => threshold.max_threshold_tokens,
             "summarizer_model" => summary.model,
             "usage" => summary.usage
           }
         }
       }}
    else
      {:error, :no_compaction_candidate} ->
        overflow_fallback(
          history,
          current_input,
          request,
          total_tokens,
          :no_compaction_candidate,
          threshold
        )

      {:error, reason} ->
        overflow_fallback(history, current_input, request, total_tokens, reason, threshold)
    end
  end

  defp unchanged(history, request) do
    %{
      history: history,
      previous_response_id: previous_response_id_for(history, request),
      compaction: nil,
      run_metadata: %{}
    }
  end

  defp overflow_fallback(history, current_input, request, total_tokens, reason, threshold) do
    if auto_truncation?(request) do
      truncate_history(history, current_input, request, total_tokens, reason, threshold)
    else
      {:error, context_overflow(total_tokens, reason, "disabled", threshold)}
    end
  end

  defp truncate_history(history, current_input, request, total_tokens, reason, threshold) do
    current_input_tokens = estimate_tokens(current_input)

    cond do
      current_input_tokens > threshold.tokens ->
        {:error, context_overflow(total_tokens, :current_input_overflow, "auto", threshold)}

      true ->
        truncated_history = truncate_history_to_budget(history, current_input, threshold.tokens)
        truncated_tokens = estimate_tokens(messages_to_items(truncated_history) ++ current_input)

        auto_truncation =
          auto_truncation_metadata(
            history,
            truncated_history,
            total_tokens,
            truncated_tokens,
            reason,
            threshold
          )

        {:ok,
         %{
           history: truncated_history,
           previous_response_id: previous_response_id_for(history, request),
           compaction: nil,
           run_metadata: %{
             "truncation" => "auto",
             "auto_truncation" => auto_truncation
           }
         }}
    end
  end

  defp auto_truncation_metadata(
         history,
         truncated_history,
         total_tokens,
         truncated_tokens,
         reason,
         threshold
       ) do
    dropped_opaque_messages = dropped_opaque_messages(history, truncated_history)

    %{
      "reason" => overflow_reason(reason),
      "estimated_input_tokens_before" => total_tokens,
      "estimated_input_tokens_after" => truncated_tokens,
      "token_threshold" => threshold.tokens,
      "context_length" => threshold.context_length,
      "threshold" => threshold.threshold,
      "max_threshold_tokens" => threshold.max_threshold_tokens,
      "dropped_message_count" => length(history) - length(truncated_history)
    }
    |> put_nonempty("dropped_opaque_messages", dropped_opaque_messages)
    |> maybe_put_count("dropped_opaque_message_count", dropped_opaque_messages)
  end

  defp dropped_opaque_messages(history, truncated_history) do
    kept_ids =
      truncated_history
      |> Enum.map(& &1.id)
      |> MapSet.new()

    history
    |> Enum.reject(&MapSet.member?(kept_ids, &1.id))
    |> Enum.flat_map(&opaque_message_audit/1)
  end

  defp opaque_message_audit(%Message{content: content} = message) when is_list(content) do
    items = opaque_item_audit(content)

    case items do
      [] ->
        []

      _nonempty ->
        [
          %{
            "message_id" => message.id,
            "response_id" => "resp_#{message.id}",
            "item_count" => length(items),
            "items" => items
          }
        ]
    end
  end

  defp opaque_message_audit(_message), do: []

  defp opaque_item_audit(items) do
    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {item, index} -> opaque_item_audit(item, index) end)
  end

  defp opaque_item_audit(%{"type" => "message", "content" => content} = item, item_index)
       when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.reject(fn {part, _part_index} -> text_content_part?(part) end)
    |> Enum.map(fn {part, part_index} ->
      opaque_ref(part, item_index, part_index)
      |> maybe_put("role", item["role"])
    end)
  end

  defp opaque_item_audit(%{} = item, item_index) do
    if text_compactable_item?(item) do
      []
    else
      [opaque_ref(item, item_index, nil)]
    end
  end

  defp opaque_item_audit(_item, _item_index), do: []

  defp opaque_ref(%{} = value, item_index, part_index) do
    refs = bounded_refs(value)

    %{
      "item_index" => item_index,
      "type" => Map.get(value, "type", "unknown")
    }
    |> maybe_put("part_index", part_index)
    |> put_nonempty("refs", refs)
    |> maybe_mark_missing_ref(refs)
  end

  defp bounded_refs(value) do
    value
    |> Map.take(@opaque_ref_keys)
    |> Enum.map(fn {key, ref_value} -> {key, bounded_ref_value(ref_value)} end)
    |> Enum.reject(fn {_key, ref_value} -> is_nil(ref_value) or ref_value == "" end)
    |> Map.new()
  end

  defp bounded_ref_value(value) when is_binary(value) do
    if String.length(value) > @max_ref_chars do
      String.slice(value, 0, @max_ref_chars) <> "...[truncated]"
    else
      value
    end
  end

  defp bounded_ref_value(value) when is_number(value) or is_boolean(value), do: value
  defp bounded_ref_value(_value), do: nil

  defp text_content_part?(%{"type" => type})
       when type in ["input_text", "output_text", "text"],
       do: true

  defp text_content_part?(%{"text" => text}) when is_binary(text), do: true
  defp text_content_part?(_part), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_nonempty(map, _key, []), do: map
  defp put_nonempty(map, _key, value) when is_map(value) and map_size(value) == 0, do: map
  defp put_nonempty(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_count(map, _key, []), do: map
  defp maybe_put_count(map, key, values), do: Map.put(map, key, length(values))

  defp maybe_mark_missing_ref(map, refs) when refs == %{},
    do: Map.put(map, "missing_durable_ref", true)

  defp maybe_mark_missing_ref(map, _refs), do: map

  defp truncate_history_to_budget(history, current_input, threshold) do
    history
    |> truncation_candidates()
    |> Enum.find([], fn candidate ->
      tool_call_prefix_valid?(messages_to_items(candidate)) and
        estimate_tokens(messages_to_items(candidate) ++ current_input) <= threshold
    end)
  end

  defp truncation_candidates(history) do
    compaction_index = last_compaction_index(history)

    candidates =
      if is_integer(compaction_index) do
        compaction = Enum.at(history, compaction_index)
        tail = Enum.drop(history, compaction_index + 1)

        keep_compaction =
          for count <- Range.new(length(tail), 0, -1) do
            [compaction | Enum.take(tail, -count)]
          end

        drop_compaction =
          for count <- Range.new(length(tail), 0, -1) do
            Enum.take(tail, -count)
          end

        keep_compaction ++ drop_compaction
      else
        for count <- Range.new(length(history), 0, -1) do
          Enum.take(history, -count)
        end
      end

    candidates
    |> Enum.uniq_by(&Enum.map(&1, fn %Message{id: id} -> id end))
  end

  defp last_compaction_index(history) do
    history
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%Message{type: "compaction"}, index}, _last -> index
      _other, last -> last
    end)
  end

  defp previous_response_id_for(history, request) do
    case Map.get(request, "previous_response_id") do
      previous_response_id when is_binary(previous_response_id) and previous_response_id != "" ->
        previous_response_id

      _missing ->
        case List.last(history) do
          %Message{id: id} -> "resp_#{id}"
          _no_history -> nil
        end
    end
  end

  defp auto_truncation?(%{"truncation" => "auto"}), do: true
  defp auto_truncation?(_request), do: false

  defp context_overflow(total_tokens, reason, truncation, threshold) do
    {:context_overflow,
     %{
       estimated_input_tokens: total_tokens,
       token_threshold: threshold.tokens,
       context_length: threshold.context_length,
       threshold: threshold.threshold,
       max_threshold_tokens: threshold.max_threshold_tokens,
       truncation: truncation,
       reason: overflow_reason(reason)
     }}
  end

  defp overflow_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp overflow_reason(reason), do: inspect(reason)

  defp compaction_candidate(history) do
    with %Message{} = anchor <- List.last(history),
         rows_after_compaction = rows_after_last_compaction(history),
         compressible_limit when compressible_limit > 0 <-
           length(rows_after_compaction) - tail_rows(),
         candidate_region = Enum.take(rows_after_compaction, compressible_limit),
         prefix = Enum.take_while(candidate_region, &text_compactable_message?/1),
         %Message{} = covers_until <- List.last(prefix) do
      {:ok,
       %{
         anchor: anchor,
         covers_until: covers_until,
         prefix: prefix,
         previous_chat_history: previous_compaction_summary(history)
       }}
    else
      _value -> {:error, :no_compaction_candidate}
    end
  end

  defp rows_after_last_compaction(history) do
    case history
         |> Enum.with_index()
         |> Enum.filter(fn {row, _index} -> row.type == "compaction" end) do
      [] ->
        history

      indexed ->
        {_row, index} = List.last(indexed)
        Enum.drop(history, index + 1)
    end
  end

  defp previous_compaction_summary(history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{type: "compaction", content: [%{"summary" => summary}]} when is_binary(summary) ->
        summary

      _row ->
        nil
    end)
  end

  defp summarize_candidate(agent_uid, candidate, request) do
    prompt =
      CompactionPrompt.build_history_user_prompt(%{
        conversation_text: conversation_text(candidate.prefix),
        previous_chat_history: candidate.previous_chat_history
      })

    request_model = Map.get(request, "model")

    summarizer_selectors(request_model)
    |> Enum.reduce_while({:error, :summarizer_model_unavailable}, fn selector, _last_error ->
      case call_summarizer(agent_uid, selector, prompt) do
        {:ok, summary} -> {:halt, {:ok, summary}}
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  defp call_summarizer(agent_uid, selector, prompt) do
    request = %{
      "model" => selector,
      "instructions" => CompactionPrompt.system_prompt(),
      "input" => prompt,
      "max_output_tokens" => @summarizer_max_output_tokens
    }

    with {:ok, runtime} <- Resolver.resolve_request_model(agent_uid, "llm", request),
         {:ok, prepared_request} <-
           Providers.build_response_request(runtime, request, stream?: false),
         {:ok, %{body: body}} <- UniversalAIRequest.request(prepared_request),
         {:ok, text} <- extract_summary_text(body) do
      {:ok,
       %{
         text: text,
         model: Map.get(runtime, "model", selector),
         selector: selector,
         usage: Map.get(body, "usage", %{})
       }}
    end
  end

  defp summarizer_selectors(request_model) do
    ["light", "primary", request_model]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp extract_summary_text(%{"output_text" => text}) when is_binary(text) do
    summary_text(text)
  end

  defp extract_summary_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(&output_item_texts/1)
    |> Enum.join("\n")
    |> summary_text()
  end

  defp extract_summary_text(%{"choices" => choices}) when is_list(choices) do
    choices
    |> Enum.map(&get_in(&1, ["message", "content"]))
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> summary_text()
  end

  defp extract_summary_text(_body), do: {:error, :empty_compaction_summary}

  defp output_item_texts(%{"content" => content}) when is_list(content) do
    Enum.flat_map(content, fn
      %{"type" => type, "text" => text}
      when type in ["output_text", "text"] and is_binary(text) ->
        [text]

      %{"text" => text} when is_binary(text) ->
        [text]

      _part ->
        []
    end)
  end

  defp output_item_texts(_item), do: []

  defp summary_text(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_compaction_summary}
      summary -> {:ok, summary}
    end
  end

  defp compaction_metadata(summary, candidate, total_tokens, flags) do
    %{
      "summarizer" => %{
        "model" => summary.model,
        "selector" => summary.selector,
        "usage" => summary.usage
      },
      "estimated_input_tokens_before" => total_tokens,
      "covered_message_count" => length(candidate.prefix)
    }
    |> Map.merge(flags)
  end

  defp request_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp request_metadata(_request), do: %{}

  defp conversation_text(messages) do
    messages
    |> Enum.with_index(1)
    |> Enum.map(fn {message, index} ->
      """
      <response index="#{index}" id="resp_#{message.id}">
      #{message_content_text(message)}
      </response>
      """
    end)
    |> Enum.join("\n")
  end

  defp message_content_text(%Message{content: content}) when is_list(content) do
    content
    |> Enum.map(&item_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp item_text(%{"type" => "message", "role" => role, "content" => content}) do
    "#{role}: #{content_text(content)}"
  end

  defp item_text(%{"type" => "function_call", "name" => name, "call_id" => call_id} = item) do
    args = Map.get(item, "arguments") || Map.get(item, "input") || ""

    "function_call #{name || "(unknown)"} call_id=#{call_id || "(none)"} arguments=#{stringify(args)}"
  end

  defp item_text(%{"type" => "function_call_output", "call_id" => call_id} = item) do
    "function_call_output call_id=#{call_id || "(none)"} output=#{stringify(Map.get(item, "output"))}"
  end

  defp item_text(%{"type" => "reasoning"} = item), do: "reasoning: #{stringify(item)}"
  defp item_text(item) when is_map(item), do: stringify(item)
  defp item_text(_item), do: ""

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp content_text(content), do: stringify(content)

  defp content_part_text(%{"type" => type, "text" => text})
       when type in ["input_text", "output_text", "text"] and is_binary(text),
       do: text

  defp content_part_text(%{"text" => text}) when is_binary(text), do: text
  defp content_part_text(part) when is_map(part), do: stringify(part)
  defp content_part_text(_part), do: ""

  defp text_compactable_message?(%Message{type: "message", status: "complete", content: content})
       when is_list(content),
       do: Enum.all?(content, &text_compactable_item?/1)

  defp text_compactable_message?(_message), do: false

  defp text_compactable_item?(%{"type" => "message", "content" => content}),
    do: text_compactable_content?(content)

  defp text_compactable_item?(%{"type" => type, "text" => text})
       when type in ["input_text", "output_text", "text"] and is_binary(text),
       do: true

  defp text_compactable_item?(%{"type" => type})
       when type in ["function_call", "function_call_output", "reasoning"],
       do: true

  defp text_compactable_item?(_item), do: false

  defp text_compactable_content?(content) when is_binary(content), do: true

  defp text_compactable_content?(content) when is_list(content) do
    Enum.all?(content, fn
      %{"type" => type} when type in ["input_text", "output_text", "text"] -> true
      %{"text" => text} when is_binary(text) -> true
      _part -> false
    end)
  end

  defp text_compactable_content?(_content), do: false

  defp messages_to_items(messages) do
    Enum.flat_map(messages, fn
      %Message{content: content} when is_list(content) -> content
      _message -> []
    end)
  end

  defp tool_call_prefix_valid?(items) when is_list(items) do
    items
    |> Enum.reduce_while(MapSet.new(), fn
      %{"type" => "function_call", "call_id" => call_id}, seen when is_binary(call_id) ->
        {:cont, MapSet.put(seen, call_id)}

      %{"type" => "function_call_output", "call_id" => call_id}, seen
      when is_binary(call_id) ->
        if MapSet.member?(seen, call_id), do: {:cont, seen}, else: {:halt, :orphaned_tool_output}

      _item, seen ->
        {:cont, seen}
    end)
    |> case do
      :orphaned_tool_output -> false
      _seen -> true
    end
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(nil), do: ""
  defp stringify(value), do: Ankole.JSON.encode!(value)

  defp tail_rows do
    config()
    |> Map.get("tail_rows", @default_tail_rows)
  end

  defp config do
    with :ok <- ensure_registered(),
         {:ok, config} <- AppConfigure.get(config_definition()) do
      config
    else
      _reason -> @default_config
    end
  end

  defp config_schema do
    Schema.new(fn value ->
      with {:ok, value} <- normalize_config(value),
           :ok <- reject_unknown_config_keys(value),
           {:ok, threshold} <- optional_threshold(value),
           {:ok, max_threshold_tokens} <- optional_max_threshold_tokens(value),
           {:ok, tail_rows} <- optional_tail_rows(value) do
        {:ok,
         %{
           "threshold" => threshold,
           "max_threshold_tokens" => max_threshold_tokens,
           "tail_rows" => tail_rows
         }}
      end
    end)
  end

  defp normalize_config(value) when is_map(value) do
    {:ok,
     Map.new(value, fn
       {key, value} when is_atom(key) -> {Atom.to_string(key), value}
       {key, value} -> {key, value}
     end)}
  end

  defp normalize_config(_value), do: {:error, :not_compaction_config}

  defp reject_unknown_config_keys(value) do
    allowed = MapSet.new(["threshold", "max_threshold_tokens", "tail_rows"])

    value
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> case do
      [] -> :ok
      keys -> {:error, {:unknown_compaction_config_keys, Enum.sort(keys)}}
    end
  end

  defp optional_threshold(value) do
    case Map.get(value, "threshold", @default_threshold_percent) do
      threshold when is_number(threshold) and threshold > 0 and threshold <= 1 ->
        {:ok, threshold * 1.0}

      _value ->
        {:error, :invalid_compaction_threshold}
    end
  end

  defp optional_tail_rows(value) do
    case Map.get(value, "tail_rows", @default_tail_rows) do
      tail_rows when is_integer(tail_rows) and tail_rows >= 0 -> {:ok, tail_rows}
      _value -> {:error, :invalid_compaction_tail_rows}
    end
  end

  defp optional_max_threshold_tokens(value) do
    case Map.get(value, "max_threshold_tokens", @default_max_threshold_tokens) do
      tokens when is_integer(tokens) and tokens > 0 -> {:ok, tokens}
      _value -> {:error, :invalid_compaction_max_threshold_tokens}
    end
  end

  defp context_length(runtime) when is_map(runtime) do
    first_positive_integer([
      Map.get(runtime, "context_length"),
      get_in(runtime, ["model_metadata", "context_length"]),
      get_in(runtime, ["model_metadata", "top_provider", "context_length"]),
      provider_model_context_length(runtime)
    ]) || @default_context_length
  end

  defp context_length(_runtime), do: @default_context_length

  defp provider_model_context_length(
         %{"provider" => %Provider{} = provider, "model" => model} = runtime
       )
       when is_binary(model) do
    capability = Map.get(runtime, "capability", "llm")
    {:ok, metadata} = ModelMetadata.model_metadata(provider, model, capability: capability)

    first_positive_integer([
      Map.get(metadata, "context_length"),
      get_in(metadata, ["top_provider", "context_length"])
    ])
  end

  defp provider_model_context_length(_runtime), do: nil

  defp max_output_tokens(request) when is_map(request) do
    first_positive_integer([
      Map.get(request, "max_output_tokens"),
      Map.get(request, "max_tokens")
    ])
  end

  defp max_output_tokens(_request), do: nil

  defp compute_threshold_tokens(context_length, threshold_percent, max_output_tokens) do
    context_length = positive_integer_or(context_length, @default_context_length)
    threshold_percent = positive_number_or(threshold_percent, @default_threshold_percent)
    output_reservation = positive_integer_or(max_output_tokens, 0)

    effective_context_length =
      case context_length - output_reservation do
        value when value > 0 -> value
        _value -> context_length
      end

    percentage_value = floor(effective_context_length * threshold_percent)
    floored = max(percentage_value, @minimum_context_length)

    tokens =
      if effective_context_length > 0 and floored >= effective_context_length do
        max(
          1,
          min(
            floor(effective_context_length * @small_context_trigger_ratio),
            effective_context_length - 1
          )
        )
      else
        floored
      end

    {tokens, effective_context_length}
  end

  defp first_positive_integer(values) do
    Enum.find_value(values, fn value ->
      case positive_integer(value) do
        nil -> false
        integer -> integer
      end
    end)
  end

  defp positive_integer_or(value, fallback) do
    positive_integer(value) || fallback
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _value -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp positive_number_or(value, _fallback) when is_number(value) and value > 0, do: value
  defp positive_number_or(_value, fallback), do: fallback
end
