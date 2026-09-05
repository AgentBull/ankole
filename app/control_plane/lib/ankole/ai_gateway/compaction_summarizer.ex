defmodule Ankole.AIGateway.CompactionSummarizer do
  @moduledoc false

  alias Ankole.AIGateway.{
    CompactionPrompt,
    CompactionRender,
    ModelMetadata,
    ResponsesPreparation,
    ResponseStream
  }

  alias Ankole.Logging

  @summarizer_profile "light"
  @summarizer_max_output_tokens 8_192
  @summarizer_retry_max_output_tokens 16_384
  @unusable_summary_reasons [:empty_compaction_summary, :invalid_summary_shape]

  def profile, do: @summarizer_profile
  def max_output_tokens, do: @summarizer_retry_max_output_tokens

  def summarize(subject_uid, items, previous_chat_history, opts \\ []) do
    with {:ok, runtime} <- resolve_summarizer_runtime(subject_uid) do
      summarize_rendered(subject_uid, runtime, items, previous_chat_history, opts)
    end
  end

  defp summarize_rendered(subject_uid, runtime, items, previous_chat_history, opts) do
    recent_context_verbatim = render_recent_context(Keyword.get(opts, :recent_items, []))
    budget = render_budget(runtime, previous_chat_history, recent_context_verbatim)
    caps = CompactionRender.default_caps()

    prompt =
      build_summarizer_prompt(items, previous_chat_history, recent_context_verbatim, budget, caps)

    case call_summarizer(subject_uid, runtime, prompt) do
      {:ok, summary} ->
        {:ok, summary}

      {:error, reason} = error ->
        if context_length_error?(reason) do
          tight_budget = max(floor(budget * 0.6), CompactionRender.min_render_budget_tokens())
          tight_caps = CompactionRender.scaled_caps(caps, 0.5)

          tight_prompt =
            build_summarizer_prompt(
              items,
              previous_chat_history,
              recent_context_verbatim,
              tight_budget,
              tight_caps
            )

          call_summarizer(subject_uid, runtime, tight_prompt)
        else
          error
        end
    end
  end

  defp build_summarizer_prompt(
         items,
         previous_chat_history,
         recent_context_verbatim,
         budget,
         caps
       ) do
    CompactionPrompt.build_history_user_prompt(%{
      conversation_text: CompactionRender.render_items(items, budget_tokens: budget, caps: caps),
      previous_chat_history: previous_chat_history,
      recent_context_verbatim: recent_context_verbatim
    })
  end

  defp render_recent_context([]), do: nil

  defp render_recent_context(items) when is_list(items) do
    text = CompactionRender.render_items(items, budget_tokens: 8_000)
    if String.trim(text) == "", do: nil, else: text
  end

  defp render_budget(runtime, previous_chat_history, recent_context_verbatim) do
    scaffold =
      CompactionRender.approx_tokens(
        CompactionPrompt.system_prompt() <>
          CompactionPrompt.build_history_user_prompt(%{conversation_text: ""})
      ) + 512

    budget =
      floor(0.8 * summarizer_context_length(runtime)) -
        scaffold -
        CompactionRender.approx_tokens(previous_chat_history || "") -
        CompactionRender.approx_tokens(recent_context_verbatim || "") -
        summarizer_output_cap(runtime)

    max(budget, CompactionRender.min_render_budget_tokens())
  end

  defp resolve_summarizer_runtime(subject_uid) do
    ResponsesPreparation.resolve_runtime(subject_uid, %{"model" => @summarizer_profile})
  end

  # A truncated summary and an unusable one have the same cause: the summarizer
  # ran out of output room, or returned nothing this round. Both retry once with
  # the larger output cap. Only the truncated case can fall back to its first
  # result, because an unusable result carries no summary to keep.
  defp call_summarizer(subject_uid, runtime, prompt) do
    case request_summary(
           subject_uid,
           runtime,
           prompt,
           summarizer_output_cap(runtime)
         ) do
      {:ok, %{truncated: true} = truncated_summary} ->
        case retry_summary(subject_uid, runtime, prompt) do
          {:ok, retried_summary} -> {:ok, retried_summary}
          {:error, _retry_failed} -> {:ok, truncated_summary}
        end

      {:error, reason} when reason in @unusable_summary_reasons ->
        retry_summary(subject_uid, runtime, prompt)

      other ->
        other
    end
  end

  defp retry_summary(subject_uid, runtime, prompt) do
    request_summary(subject_uid, runtime, prompt, summarizer_retry_output_cap(runtime))
  end

  # Scale the output reservation with the summarizer's window so a small-context
  # summarizer keeps enough input render budget for the tighter context-error retry.
  defp summarizer_output_cap(runtime) do
    min(@summarizer_max_output_tokens, floor(summarizer_context_length(runtime) * 0.2))
  end

  defp summarizer_retry_output_cap(runtime) do
    min(@summarizer_retry_max_output_tokens, floor(summarizer_context_length(runtime) * 0.4))
  end

  defp request_summary(subject_uid, runtime, prompt, max_output_tokens) do
    cache_key = get_in(runtime, ["request_context", "cache_key"])

    request =
      %{
        "model" => @summarizer_profile,
        "instructions" => CompactionPrompt.system_prompt(),
        "input" => prompt,
        "reasoning" => %{"effort" => "low"},
        "max_output_tokens" => max_output_tokens
      }
      |> maybe_put_prompt_cache_key(cache_key)

    with {:ok, %{request: request, spec: prepared_request}} <-
           ResponsesPreparation.prepare_with_runtime(subject_uid, runtime, request, stream?: true),
         {:ok, outcome, _meta} <-
           ResponseStream.collect(subject_uid, request, prepared_request,
             caller: "compaction.summary"
           ),
         {:ok, body} <- compaction_summary_body(outcome),
         {:ok, text} <- extract_summary(body, max_output_tokens) do
      {:ok,
       %{
         text: text,
         model: Map.get(runtime, "model", @summarizer_profile),
         usage: Map.get(body, "usage", %{}),
         truncated: summary_truncated?(body)
       }}
    end
  end

  # An unusable summary leaves no trace in the response the caller receives, so
  # record the summarizer's terminal facts here. Without them an empty summary
  # cannot be told apart from an exhausted output budget or a refused response.
  defp extract_summary(body, max_output_tokens) do
    case extract_summary_text(body) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Logging.warning(
          "ai_gateway.compaction_summary_unusable",
          "compaction summarizer returned no usable summary",
          %{
            error_code: Atom.to_string(reason),
            max_output_tokens: max_output_tokens,
            response_status: Map.get(body, "status"),
            incomplete_reason: get_in(body, ["incomplete_details", "reason"]),
            output_item_types: output_item_types(body),
            usage: Map.get(body, "usage", %{})
          }
        )

        {:error, reason}
    end
  end

  defp output_item_types(%{"output" => output}) when is_list(output) do
    output
    |> Enum.map(&Map.get(&1, "type"))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp output_item_types(_body), do: []

  defp compaction_summary_body(%{terminal_error: nil, terminal_response: %{} = response}),
    do: {:ok, response}

  defp compaction_summary_body(%{terminal_error: error}),
    do: {:error, {:compaction_summary_failed, error}}

  defp compaction_summary_body(_outcome),
    do: {:error, :compaction_summary_missing_terminal_response}

  defp maybe_put_prompt_cache_key(request, cache_key)
       when is_binary(cache_key) and cache_key != "",
       do: Map.put(request, "prompt_cache_key", cache_key)

  defp maybe_put_prompt_cache_key(request, _cache_key), do: request

  defp summary_truncated?(%{"incomplete_details" => %{"reason" => "max_output_tokens"}}), do: true

  defp summary_truncated?(%{"choices" => choices}) when is_list(choices) do
    Enum.any?(choices, &(Map.get(&1, "finish_reason") == "length"))
  end

  defp summary_truncated?(_body), do: false

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
    text = String.trim(text)

    cond do
      text == "" ->
        {:error, :empty_compaction_summary}

      not has_summary_heading?(text) ->
        {:error, :invalid_summary_shape}

      true ->
        {:ok, text}
    end
  end

  defp has_summary_heading?(text) do
    text
    |> String.trim()
    |> String.split("\n")
    |> Enum.any?(&String.starts_with?(&1, "## "))
  end

  defp context_length_error?(reason) do
    reason
    |> inspect()
    |> String.match?(~r/context|too long|too large|maximum.*(length|tokens)/i)
  end

  defp summarizer_context_length(runtime),
    do:
      ModelMetadata.runtime_context_length(runtime) ||
        CompactionRender.fallback_summarizer_context_tokens()
end
