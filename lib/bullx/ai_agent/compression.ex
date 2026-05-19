defmodule BullX.AIAgent.Compression do
  @moduledoc """
  Context compression and request-time prompt-cache helpers.

  The implementation keeps the durable rule simple: summaries are Messages and
  raw Messages remain untouched. Provider cache hints are request-time metadata
  and never become Conversation truth.
  """

  alias BullX.AIAgent.{Conversation, Conversations, Message, Profile, Time}
  alias BullX.LLM

  @default_context_limit_tokens 16_000
  @compression_request_budget_ratio 0.80
  @protected_tail_ratio 0.20
  @large_tool_result_bytes 8_000
  @max_auto_attempts 3

  @spec manual_compress(Conversation.t(), map()) :: {:ok, map()} | {:error, term()}
  def manual_compress(%Conversation{} = conversation, context) when is_map(context) do
    branch = Conversations.active_branch(conversation)
    expected_raw_leaf_id = List.last(branch) && List.last(branch).id

    with nil <- existing_summary_for_context(context),
         {:ok, profile} <- fetch_profile(context),
         {_from_message, _to_message, seen_messages} <- compressible_interval(branch, profile),
         {:ok, summary, seen_messages} <- call_compression_model(profile, seen_messages) do
      write_summary(
        conversation,
        expected_raw_leaf_id,
        List.first(seen_messages),
        List.last(seen_messages),
        seen_messages,
        summary,
        context
      )
    else
      %Message{} = message ->
        {:ok, %{status: :ok, summary_message_id: message.id}}

      nil ->
        {:ok, %{status: :diagnostic, reason: "no_compressible_interval"}}

      {:error, :empty_summary} ->
        {:ok, %{status: :diagnostic, reason: "compression_failed"}}

      {:error, :branch_changed} ->
        {:ok, %{status: :diagnostic, reason: "branch_changed"}}

      {:error, _reason} ->
        {:ok, %{status: :diagnostic, reason: "compression_failed"}}
    end
  end

  @spec compact_large_results([ReqLLM.Message.t()], keyword()) :: [ReqLLM.Message.t()]
  def compact_large_results(messages, opts \\ []) when is_list(messages) do
    {compactable_prefix, protected_tail} =
      split_provider_tail(messages, prompt_tail_budget(Keyword.get(opts, :profile)))

    Enum.map(compactable_prefix, fn
      %ReqLLM.Message{role: :tool, content: content} = message when is_list(content) ->
        %{message | content: Enum.map(content, &compact_content_part/1)}

      message ->
        message
    end) ++ protected_tail
  end

  @spec apply_prompt_cache_hints(map(), keyword()) :: map()
  def apply_prompt_cache_hints(rendered, opts \\ []) when is_map(rendered) and is_list(opts) do
    case prompt_cache_enabled?(Keyword.get(opts, :profile)) do
      true ->
        put_in(rendered, [:diagnostics, :prompt_cache_hint], %{
          enabled: true,
          stable_prefix: rendered.system_prompt.stable_prefix,
          provider_contract: "best_effort"
        })

      false ->
        put_in(rendered, [:diagnostics, :prompt_cache_hint], %{enabled: false})
    end
  end

  @spec over_budget?(map(), Profile.t()) :: boolean()
  def over_budget?(rendered, %Profile{} = profile) when is_map(rendered) do
    estimate_messages(rendered.messages || []) >= compression_threshold(profile)
  end

  @spec auto_compress(Conversation.t(), map(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  def auto_compress(%Conversation{} = conversation, context, attempt \\ 0) when is_map(context) do
    cond do
      attempt >= @max_auto_attempts ->
        {:ok, %{status: :diagnostic, reason: "compression_attempt_limit"}}

      true ->
        context
        |> Map.put(:compression_trigger, "auto_generation")
        |> then(&manual_compress(conversation, &1))
    end
  end

  defp existing_summary_for_context(%{target_session_entry_id: entry_id})
       when is_binary(entry_id),
       do: Conversations.summary_for_entry(entry_id)

  defp existing_summary_for_context(_context), do: nil

  defp compressible_interval(branch, %Profile{} = profile) do
    exchanges =
      branch
      |> Enum.reject(&protected_message?/1)
      |> complete_exchanges()

    {candidates, _tail} = split_tail_exchanges(exchanges, prompt_tail_budget(profile))

    case candidates do
      [] ->
        nil

      candidates ->
        seen_messages = List.flatten(candidates)
        {List.first(seen_messages), List.last(seen_messages), seen_messages}
    end
  end

  defp protected_message?(%Message{status: :generating}), do: true
  defp protected_message?(%Message{kind: :summary}), do: true
  defp protected_message?(%Message{role: :im_ambient, kind: :normal}), do: true
  defp protected_message?(_message), do: false

  defp complete_exchanges(messages) do
    {exchanges, current} =
      Enum.reduce(messages, {[], []}, fn message, {exchanges, current} ->
        case source_message?(message) do
          true -> {push_complete_exchange(exchanges, current), [message]}
          false -> {exchanges, current ++ [message]}
        end
      end)

    push_complete_exchange(exchanges, current)
  end

  defp push_complete_exchange(exchanges, []), do: exchanges

  defp push_complete_exchange(exchanges, messages) do
    case complete_exchange?(messages) do
      true -> exchanges ++ [messages]
      false -> exchanges
    end
  end

  defp source_message?(%Message{role: :user, kind: :normal}), do: true
  defp source_message?(%Message{role: :im_ambient, kind: :introspection}), do: true
  defp source_message?(_message), do: false

  defp complete_exchange?([source | rest]) do
    source_message?(source) and Enum.any?(rest, &assistant_complete?/1) and
      complete_tool_pairs?(rest)
  end

  defp complete_exchange?(_messages), do: false

  defp assistant_complete?(%Message{role: :assistant, kind: :normal, status: :complete}), do: true
  defp assistant_complete?(_message), do: false

  defp complete_tool_pairs?(messages) do
    required =
      messages
      |> Enum.filter(&assistant_complete?/1)
      |> Enum.flat_map(&tool_call_ids/1)
      |> MapSet.new()

    returned =
      messages
      |> Enum.filter(&tool_result_message?/1)
      |> Enum.flat_map(&tool_result_ids/1)
      |> MapSet.new()

    MapSet.subset?(required, returned)
  end

  defp tool_call_ids(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "tool_call"))
    |> Enum.map(&Map.get(&1, "tool_call_id"))
    |> Enum.filter(&is_binary/1)
  end

  defp tool_result_message?(%Message{role: :tool, kind: :normal, status: :complete}), do: true
  defp tool_result_message?(_message), do: false

  defp tool_result_ids(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "tool_result"))
    |> Enum.map(&Map.get(&1, "tool_call_id"))
    |> Enum.filter(&is_binary/1)
  end

  defp fetch_profile(%{profile: %Profile{} = profile}), do: {:ok, profile}
  defp fetch_profile(_context), do: {:error, :missing_profile}

  defp call_compression_model(%Profile{} = profile, seen_messages) do
    call_compression_model(profile, seen_messages, 0)
  end

  defp call_compression_model(%Profile{} = profile, seen_messages, attempt) do
    with {:ok, seen_messages} <- shrink_to_request_budget(profile, seen_messages, attempt) do
      do_call_compression_model(profile, seen_messages, attempt)
    end
  end

  defp do_call_compression_model(%Profile{} = profile, seen_messages, attempt) do
    prompt = compression_prompt(seen_messages)

    case LLM.chat(
           profile.compression_model,
           [%ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text(prompt)]}],
           reasoning_effort: profile.compression_model_reasoning_effort,
           tools: []
         ) do
      {:ok, %{tool_calls: [_ | _]}} ->
        {:error, :compression_tool_call}

      {:ok, %{text: text} = result} ->
        case String.trim(text || "") do
          "" ->
            {:error, :empty_summary}

          summary ->
            {:ok,
             %{
               text: summary,
               usage: result.usage,
               provider_id: result.provider_id,
               model_id: result.model_id
             }, seen_messages}
        end

      {:error, reason} ->
        case oversized_error?(reason) do
          true -> retry_shrunken_compression(profile, seen_messages, attempt)
          false -> {:error, reason}
        end
    end
  end

  defp compression_prompt(seen_messages) do
    [
      "Summarize this BullX AIAgent conversation segment for future context. ",
      "Preserve decisions, constraints, progress, relevant files or records, current work, and next step. ",
      "Do not include hidden reasoning or unsupported facts. ",
      "If any line says content was omitted or represented by a marker, disclose that limitation safely.\n\n",
      Enum.map_join(seen_messages, "\n", &message_summary_line/1)
    ]
    |> IO.iodata_to_binary()
  end

  defp shrink_to_request_budget(profile, seen_messages, attempt) do
    case estimate_prompt_tokens(seen_messages) <= compression_request_budget(profile) do
      true -> {:ok, seen_messages}
      false -> retry_shrunken_compression(profile, seen_messages, attempt)
    end
  end

  defp retry_shrunken_compression(_profile, _seen_messages, attempt)
       when attempt >= @max_auto_attempts,
       do: {:error, :compression_request_too_large}

  defp retry_shrunken_compression(profile, seen_messages, attempt) do
    case drop_oldest_exchange(seen_messages) do
      [] -> {:error, :compression_request_too_large}
      shrunken -> call_compression_model(profile, shrunken, attempt + 1)
    end
  end

  defp write_summary(
         conversation,
         expected_raw_leaf_id,
         from_message,
         to_message,
         seen_messages,
         summary,
         context
       ) do
    now = DateTime.utc_now(:microsecond)
    time_range = original_dialogue_time_range(seen_messages)
    summary_text = summary_text(summary.text, time_range)

    attrs = %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :summary,
      status: :complete,
      content: [%{"type" => "summary_text", "text" => summary_text}],
      covers_range: %{"from_id" => from_message.id, "to_id" => to_message.id},
      target_session_id: Map.get(context, :target_session_id),
      target_session_entry_id: Map.get(context, :target_session_entry_id),
      metadata: %{
        "source_leaf_message_id" => expected_raw_leaf_id,
        "original_dialogue_time_range" => time_range,
        "trigger" => Map.get(context, :compression_trigger, "manual_command"),
        "compression" => %{
          "estimated_input_tokens" => estimate_messages(seen_messages),
          "estimated_output_budget" => 1_000,
          "usage" => summary.usage,
          "usage_source" => if(is_nil(summary.usage), do: "estimated", else: "provider_reported"),
          "provider_id" => summary.provider_id,
          "model_id" => summary.model_id
        },
        "created_at" => DateTime.to_iso8601(now)
      }
    }

    append_opts =
      case Map.get(context, :lease_id) do
        lease_id when is_binary(lease_id) -> [move_leaf?: true, lease_id: lease_id]
        _other -> [move_leaf?: true, require_inactive_generation?: true]
      end

    case Conversations.append_message_if_raw_leaf(
           conversation,
           expected_raw_leaf_id,
           attrs,
           append_opts
         ) do
      {:ok, _conversation, message} -> {:ok, %{status: :ok, summary_message_id: message.id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compact_content_part(%ReqLLM.Message.ContentPart{type: :text, text: text} = part)
       when is_binary(text) and byte_size(text) > @large_tool_result_bytes do
    case compactable_tool_result?(text) do
      true -> %{part | text: compact_tool_result_text(text)}
      false -> part
    end
  end

  defp compact_content_part(part), do: part

  defp compact_tool_result_text(text) do
    payload =
      case Jason.decode(text) do
        {:ok, decoded} when is_map(decoded) ->
          %{
            "omitted_tool_result" => true,
            "reason" => "large_result",
            "original_sha256" => "sha256:" <> BullX.Ext.generic_hash(text),
            "original_byte_size" => byte_size(text),
            "preview" => String.slice(Jason.encode!(decoded), 0, 1_000)
          }

        _other ->
          %{
            "omitted_tool_result" => true,
            "reason" => "large_result",
            "original_sha256" => "sha256:" <> BullX.Ext.generic_hash(text),
            "original_byte_size" => byte_size(text),
            "preview" => String.slice(text, 0, 1_000)
          }
      end

    Jason.encode!(payload)
  end

  defp compactable_tool_result?(text) do
    with {:ok, %{} = decoded} <- Jason.decode(text),
         compactable_payload when is_map(compactable_payload) <- compactable_payload(decoded),
         true <- Map.get(compactable_payload, "compactable") == true,
         false <- high_risk_tool_result?(compactable_payload) do
      true
    else
      _other -> false
    end
  end

  defp compactable_payload(%{"ok" => true, "result" => %{} = result}), do: result
  defp compactable_payload(%{} = decoded), do: decoded

  defp high_risk_tool_result?(decoded) do
    risk = Map.get(decoded, "risk")
    effect = Map.get(decoded, "external_side_effect") || Map.get(decoded, "requires_approval")
    risk in ["high", "privileged", "financial", "legal", "customer_facing"] or effect == true
  end

  defp prompt_cache_enabled?(%Profile{} = profile), do: profile.context.prompt_cache
  defp prompt_cache_enabled?(_profile), do: true

  defp split_tail_exchanges([], _budget), do: {[], []}

  defp split_tail_exchanges(exchanges, budget) do
    {tail_reversed, prefix_reversed, _tokens} =
      exchanges
      |> Enum.reverse()
      |> Enum.reduce({[], [], 0}, fn exchange, {tail, prefix, tokens} ->
        exchange_tokens = estimate_messages(exchange)

        cond do
          tail == [] ->
            {[exchange | tail], prefix, tokens + exchange_tokens}

          tokens < budget ->
            {[exchange | tail], prefix, tokens + exchange_tokens}

          true ->
            {tail, [exchange | prefix], tokens}
        end
      end)

    {prefix_reversed, tail_reversed}
  end

  defp split_provider_tail([], _budget), do: {[], []}

  defp split_provider_tail(messages, budget) do
    {tail_reversed, prefix_reversed, _tokens} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], [], 0}, fn message, {tail, prefix, tokens} ->
        message_tokens = estimate_message(message)

        cond do
          tail == [] ->
            {[message | tail], prefix, tokens + message_tokens}

          tokens < budget ->
            {[message | tail], prefix, tokens + message_tokens}

          true ->
            {tail, [message | prefix], tokens}
        end
      end)

    {prefix_reversed, tail_reversed}
  end

  defp compression_threshold(%Profile{} = profile) do
    limit =
      profile.context
      |> Map.get(:context_limit_tokens, @default_context_limit_tokens)
      |> case do
        value when is_integer(value) and value > 0 -> value
        _other -> @default_context_limit_tokens
      end

    ratio = profile.context.compression_threshold_ratio
    max(1, trunc(limit * ratio))
  end

  defp prompt_tail_budget(%Profile{} = profile),
    do: max(1, trunc(compression_threshold(profile) * @protected_tail_ratio))

  defp prompt_tail_budget(_profile),
    do: max(1, trunc(@default_context_limit_tokens * 0.70 * @protected_tail_ratio))

  defp compression_request_budget(%Profile{} = profile) do
    profile.context
    |> Map.get(:context_limit_tokens, @default_context_limit_tokens)
    |> case do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_context_limit_tokens
    end
    |> Kernel.*(@compression_request_budget_ratio)
    |> trunc()
    |> max(1)
  end

  defp summary_text(body, time_range) do
    [
      "<meta>original_dialogue_time_range: ",
      time_range,
      "</meta>\n",
      body
    ]
    |> IO.iodata_to_binary()
  end

  defp message_summary_line(%Message{role: role, kind: kind, content: content} = message) do
    text = Enum.map_join(content, "", &summarizer_block_text/1)

    case text do
      "" -> "- #{role}/#{kind}: [no provider-visible content; message_id=#{message.id}]"
      _text -> "- #{role}/#{kind}: #{text}"
    end
  end

  defp summarizer_block_text(%{"type" => "text", "text" => text}) when is_binary(text),
    do: bounded_text(text, "text")

  defp summarizer_block_text(%{"type" => "summary_text", "text" => text}) when is_binary(text),
    do: bounded_text(text, "summary_text")

  defp summarizer_block_text(%{"type" => "tool_call"} = block) do
    "[tool_call id=#{block["tool_call_id"]} name=#{block["name"]} arguments=#{safe_json(block["arguments"] || %{})}]"
  end

  defp summarizer_block_text(%{"type" => "tool_result"} = block) do
    payload =
      case block do
        %{"is_error" => true, "error" => error} -> %{"ok" => false, "error" => error}
        %{"is_error" => false, "result" => result} -> %{"ok" => true, "result" => result}
        _other -> %{"ok" => false, "error" => %{"code" => "malformed_tool_result"}}
      end

    "[tool_result id=#{block["tool_call_id"]} #{bounded_json(payload, "tool_result")}]"
  end

  defp summarizer_block_text(%{"type" => "error"} = block), do: "[error #{safe_json(block)}]"

  defp summarizer_block_text(%{"type" => "human_steering_note"} = block) do
    "[human_steering_note command_entry_id=#{block["command_entry_id"]} #{bounded_text(block["text"] || "", "steering")}]"
  end

  defp summarizer_block_text(%{"type" => "omitted_marker"} = block),
    do: "[omitted_marker reason=#{block["reason"]}]"

  defp summarizer_block_text(block), do: "[unsupported_content_marker #{safe_json(block)}]"

  defp bounded_text(text, label)
       when is_binary(text) and byte_size(text) > @large_tool_result_bytes do
    "[#{label}_omitted original_sha256=sha256:#{BullX.Ext.generic_hash(text)} original_byte_size=#{byte_size(text)} preview=#{String.slice(text, 0, 1_000)}]"
  end

  defp bounded_text(text, _label) when is_binary(text), do: text

  defp bounded_json(value, label) do
    value
    |> Jason.encode!()
    |> bounded_text(label)
  end

  defp safe_json(value), do: Jason.encode!(value)

  defp estimate_prompt_tokens(messages) do
    messages
    |> compression_prompt()
    |> byte_size()
    |> div(4)
    |> max(1)
  end

  defp drop_oldest_exchange(messages) do
    messages
    |> complete_exchanges()
    |> tl_or_empty()
    |> List.flatten()
  end

  defp tl_or_empty([_oldest | rest]), do: rest
  defp tl_or_empty([]), do: []

  defp oversized_error?(reason) when is_atom(reason),
    do: reason in [:context_length_exceeded, :token_limit_exceeded, :request_too_large]

  defp oversized_error?({reason, _detail}) when is_atom(reason), do: oversized_error?(reason)

  defp oversized_error?(%{code: code}) when is_binary(code), do: oversized_error_code?(code)
  defp oversized_error?(%{"code" => code}) when is_binary(code), do: oversized_error_code?(code)
  defp oversized_error?(_reason), do: false

  defp oversized_error_code?(code) do
    String.contains?(code, "context") or String.contains?(code, "token") or
      String.contains?(code, "too_large")
  end

  defp original_dialogue_time_range(messages) do
    datetimes =
      messages
      |> Enum.map(&message_time/1)
      |> Enum.reject(&is_nil/1)

    case datetimes do
      [] ->
        now = DateTime.utc_now(:second)
        "#{format_minute(now)} to #{format_minute(now)}"

      [_ | _] ->
        first = Enum.min_by(datetimes, &DateTime.to_unix(&1, :microsecond))
        last = Enum.max_by(datetimes, &DateTime.to_unix(&1, :microsecond))
        "#{format_minute(first)} to #{format_minute(last)}"
    end
  end

  defp message_time(%Message{metadata: %{"time_awareness" => %{"send_at" => send_at}}}) do
    case DateTime.from_iso8601(send_at) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp message_time(%Message{inserted_at: inserted_at}), do: inserted_at

  defp format_minute(datetime), do: Time.format(datetime, "%Y-%m-%d %H:%M", nil)

  defp estimate_messages(messages) do
    messages
    |> Enum.map(&estimate_message/1)
    |> Enum.sum()
  end

  defp estimate_message(%Message{content: content}) do
    content
    |> Jason.encode!()
    |> byte_size()
    |> div(4)
    |> max(1)
  end

  defp estimate_message(%ReqLLM.Message{} = message) do
    %{
      role: message.role,
      content: Enum.map(List.wrap(message.content), &content_part_text/1),
      tool_call_id: message.tool_call_id,
      tool_calls: Enum.map(List.wrap(message.tool_calls), &tool_call_for_estimate/1)
    }
    |> Jason.encode!()
    |> byte_size()
    |> div(4)
    |> max(1)
  end

  defp content_part_text(%ReqLLM.Message.ContentPart{text: text}) when is_binary(text), do: text
  defp content_part_text(value) when is_binary(value), do: value
  defp content_part_text(value), do: inspect(value, limit: 5, printable_limit: 200)

  defp tool_call_for_estimate(%ReqLLM.ToolCall{} = call) do
    ReqLLM.ToolCall.to_map(call)
  end

  defp tool_call_for_estimate(call), do: inspect(call, limit: 5, printable_limit: 200)
end
