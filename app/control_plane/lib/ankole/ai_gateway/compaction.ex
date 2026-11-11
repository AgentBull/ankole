defmodule Ankole.AIGateway.Compaction do
  alias Ankole.AIGateway.ResponseChain

  @moduledoc """
  AIGateway-owned automatic history compaction.

  Automatic token decisions anchor on the newest cumulative provider-returned
  usage snapshot stored on the visible AIGateway history, calibrated with a
  bounded `wire_ratio` delta projection for unmeasured trailing items (such as
  journaled tool outputs, `current_input`, and newly mounted tools) and guarded
  by anti-thrash hysteresis when fixed prompt overhead keeps post-compaction
  usage near the trigger.
  """

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CompactionHistory
  alias Ankole.AIGateway.CompactionPolicy
  alias Ankole.AIGateway.CompactionSummarizer
  alias Ankole.AIGateway.CompactionRetention
  alias Ankole.AIGateway.UpstreamCompaction
  alias Ankole.AIGateway.UsageLedger
  alias Ankole.AIGateway.Schemas.Message

  alias Ankole.AIGateway.CompactionCandidate

  @stable_tail_summary "Earlier conversation history was omitted because it exceeded the active context budget."
  @min_productive_reduction_ratio 0.08
  @hysteresis_window_share 0.05
  @min_hysteresis_floor_tokens 4_000
  @min_prefix_yield_cap_tokens 4_000
  @real_window_floor_tokens 64_000
  @hard_context_ceiling_share 0.97

  @type history_plan :: %{
          history: [Message.t()],
          current_input: [map()],
          injection: map(),
          previous_response_id: binary() | nil,
          expected_previous_response_id: binary() | nil,
          compaction:
            nil
            | %{
                artifact_attrs: map(),
                checkpoint_metadata: map()
              },
          run_metadata: map()
        }

  # The automatic plan path and the manual `/compress` path keep separate
  # skeletons on purpose; each context bundles only the arguments that its
  # own path passes together.
  defmodule PlanContext do
    @moduledoc false
    @enforce_keys [
      :subject_uid,
      :conversation_id,
      :history,
      :current_input,
      :injection,
      :brain_context_pack,
      :request,
      :total_tokens,
      :threshold,
      :runtime,
      :issuer,
      :native_state,
      :upstream_compaction?
    ]
    # A required checkpoint replaces a history that no longer fits the model's
    # context. An optional one only keeps a history that still fits small.
    defstruct @enforce_keys ++
                [
                  brain_context: nil,
                  original_injection: nil,
                  required?: true,
                  projected_tokens: 0,
                  delta_tokens: 0,
                  wire_ratio: 1.0,
                  synthetic_usage?: false,
                  trigger: :history_usage
                ]
  end

  @doc false
  @spec maybe_plan_history(String.t(), binary(), [Message.t()], [map()], map(), map(), map()) ::
          {:ok, history_plan()} | {:error, term()}
  def maybe_plan_history(
        subject_uid,
        conversation_id,
        history,
        current_input,
        injection,
        request,
        runtime \\ %{},
        opts \\ []
      )
      when is_list(history) and is_list(current_input) and is_map(request) do
    projection =
      CompactionHistory.preflight_usage_projection(subject_uid, history, current_input, request)

    total_tokens = projection.history_tokens
    projected_tokens = projection.projected_tokens
    threshold = CompactionPolicy.threshold_spec(runtime, request)
    upstream_compaction? = CompactionPolicy.upstream_compaction?()

    with {:ok, native_state} <-
           CompactionHistory.native_checkpoint_state(subject_uid, history, runtime) do
      context = %PlanContext{
        brain_context: Keyword.get(opts, :brain_context),
        subject_uid: subject_uid,
        conversation_id: conversation_id,
        history: history,
        current_input: current_input,
        injection: injection,
        brain_context_pack: [],
        request: request,
        total_tokens: total_tokens,
        projected_tokens: projected_tokens,
        delta_tokens: projection.delta_tokens,
        wire_ratio: projection.wire_ratio,
        synthetic_usage?: projection.synthetic_usage?,
        threshold: threshold,
        runtime: runtime,
        issuer: Map.get(runtime, "provider_id"),
        native_state: native_state,
        upstream_compaction?: upstream_compaction?
      }

      cond do
        CompactionHistory.force_local_checkpoint?(native_state, upstream_compaction?) ->
          %{context | trigger: :native_checkpoint}
          |> prepare_checkpoint_context()
          |> plan_local_compact_history()

        total_tokens > threshold.tokens ->
          maybe_compact_with_hysteresis(context)

        projected_tokens > threshold.tokens ->
          maybe_compact_preflight_delta(context)

        provider_history_checkpoint_due?(history) ->
          plan_provider_history_checkpoint(context)

        true ->
          {:ok, unchanged(context)}
      end
    end
  end

  defp maybe_compact_with_hysteresis(%PlanContext{} = context) do
    case compaction_cooldown(context.history, context.projected_tokens, context.threshold) do
      {:suppress, cooldown_metadata} ->
        if provider_history_checkpoint_due?(context.history) do
          plan_provider_history_checkpoint(context)
        else
          {:ok,
           unchanged_with_metadata(context, %{"auto_compaction_cooldown" => cooldown_metadata})}
        end

      :proceed ->
        context |> prepare_checkpoint_context() |> plan_compact_history()
    end
  end

  defp maybe_compact_preflight_delta(%PlanContext{} = context) do
    case compaction_cooldown(context.history, context.projected_tokens, context.threshold) do
      {:suppress, cooldown_metadata} ->
        if provider_history_checkpoint_due?(context.history) do
          plan_provider_history_checkpoint(context)
        else
          {:ok,
           unchanged_with_metadata(context, %{"auto_compaction_cooldown" => cooldown_metadata})}
        end

      :proceed ->
        required? = context.projected_tokens > context.threshold.effective_context_length

        preflight_context =
          %{context | required?: required?, trigger: :preflight_delta}
          |> prepare_checkpoint_context()

        case plan_compact_history(preflight_context) do
          {:ok, plan} -> {:ok, plan}
          {:error, _reason} when not required? -> {:ok, unchanged(context)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp provider_history_checkpoint_due?(history) do
    history
    |> CompactionHistory.messages_to_items()
    |> CompactionPolicy.provider_history_trigger?()
  end

  # The history still fits the model's context, so a checkpoint that cannot be
  # written leaves the request on the full history. Truncating it would drop
  # work that the model can still read.
  defp plan_provider_history_checkpoint(%PlanContext{} = context) do
    case %{context | required?: false, trigger: :provider_history}
         |> prepare_checkpoint_context()
         |> plan_compact_history() do
      {:ok, plan} -> {:ok, plan}
      {:error, _reason} -> {:ok, unchanged(context)}
    end
  end

  defp compaction_cooldown(history, projected_tokens, threshold) do
    with {[%Message{type: :checkpoint, metadata: %{} = metadata}], _post_rows} <-
           CompactionHistory.split_last_compaction(history),
         true <- Map.get(metadata, "auto") == true and is_map(Map.get(metadata, "summarizer")),
         before_tokens when is_integer(before_tokens) and before_tokens > 0 <-
           prior_compaction_baseline_tokens(metadata),
         first_post_tokens when first_post_tokens > threshold.tokens <-
           CompactionHistory.first_post_checkpoint_usage_tokens(history),
         true <-
           before_tokens - first_post_tokens <
             before_tokens * @min_productive_reduction_ratio do
      hysteresis_tokens = hysteresis_budget_tokens(threshold)
      growth_tokens = max(projected_tokens - first_post_tokens, 0)
      hard_ceiling = hard_context_ceiling_tokens(threshold)

      if growth_tokens < hysteresis_tokens and projected_tokens <= hard_ceiling do
        {:suppress,
         %{
           "reason" => "unproductive_previous_compaction",
           "previous_tokens_before" => before_tokens,
           "first_post_checkpoint_tokens" => first_post_tokens,
           "projected_input_tokens" => projected_tokens,
           "growth_since_checkpoint_tokens" => growth_tokens,
           "hysteresis_tokens" => hysteresis_tokens
         }}
      else
        :proceed
      end
    else
      _not_in_cooldown -> :proceed
    end
  end

  defp prior_compaction_baseline_tokens(metadata) do
    projected = Map.get(metadata, "projected_tokens_before")
    before = Map.get(metadata, "history_usage_tokens_before")

    cond do
      is_integer(projected) and is_integer(before) -> max(projected, before)
      is_integer(before) -> before
      is_integer(projected) -> projected
      true -> nil
    end
  end

  defp hysteresis_budget_tokens(threshold) do
    max(
      floor(threshold.tokens * @hysteresis_window_share),
      min(@min_hysteresis_floor_tokens, div(threshold.tokens, 2))
    )
  end

  defp hard_context_ceiling_tokens(threshold) do
    floor(threshold.effective_context_length * @hard_context_ceiling_share)
  end

  @doc false
  @spec plan_replay_recovery(String.t(), binary(), binary(), [map()], map(), map(), map()) ::
          {:ok, history_plan()} | {:error, term()}
  def plan_replay_recovery(
        subject_uid,
        conversation_id,
        previous_response_id,
        current_input,
        injection,
        request,
        runtime,
        opts \\ []
      )
      when is_binary(previous_response_id) and is_list(current_input) and is_map(request) and
             is_map(runtime) do
    history =
      conversation_id
      |> ResponseChain.expand_history(
        previous_response_id: previous_response_id,
        stop_at_checkpoint: false
      )
      |> Enum.reject(&(&1.type == :checkpoint))

    recovery_tail_rows = min(CompactionPolicy.tail_rows(), max(length(history) - 1, 0))

    total_tokens = CompactionHistory.history_usage_tokens(history)

    context = %PlanContext{
      brain_context: Keyword.get(opts, :brain_context),
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      current_input: current_input,
      injection: injection,
      brain_context_pack: [],
      request: request,
      total_tokens: total_tokens,
      projected_tokens: total_tokens,
      threshold: CompactionPolicy.threshold_spec(runtime, request),
      runtime: runtime,
      issuer: nil,
      native_state: :none,
      upstream_compaction?: false,
      trigger: :replay_recovery
    }

    context
    |> prepare_checkpoint_context()
    |> plan_local_compact_history(recovery_tail_rows)
  end

  defp prepare_checkpoint_context(%PlanContext{} = context) do
    input = context.current_input
    original_injection = context.original_injection || context.injection
    injection = Map.drop(original_injection, ~w(brain_context_pack brain_context_pack_claimed))

    pack =
      CompactionArtifacts.checkpoint_pack(
        context.subject_uid,
        context.conversation_id,
        context.request,
        input,
        context.history,
        brain_context: context.brain_context
      )

    %{
      context
      | current_input: input,
        original_injection: original_injection,
        injection: injection,
        brain_context_pack: pack
    }
  end

  @doc false
  @spec put_checkpoint_response_id(map(), binary() | nil) :: map()
  def put_checkpoint_response_id(%{"auto_compaction" => %{} = metadata} = run_metadata, id) do
    Map.put(run_metadata, "auto_compaction", Map.put(metadata, "response_id", id))
  end

  def put_checkpoint_response_id(%{"auto_truncation" => %{} = metadata} = run_metadata, id) do
    Map.put(run_metadata, "auto_truncation", Map.put(metadata, "response_id", id))
  end

  def put_checkpoint_response_id(run_metadata, _id), do: run_metadata

  defp plan_compact_history(%PlanContext{} = context) do
    %PlanContext{
      subject_uid: subject_uid,
      history: history,
      request: request,
      runtime: runtime,
      upstream_compaction?: upstream_compaction?
    } = context

    with {:ok, input} <- CompactionHistory.history_items_for_artifact(subject_uid, history),
         {:ok, input} <- CompactionArtifacts.resolve_input_handles(subject_uid, input) do
      case UpstreamCompaction.compact(runtime, input, request,
             enabled?: upstream_compaction?,
             subject_uid: subject_uid
           ) do
        {:ok, upstream} ->
          upstream_history_plan(context, upstream)

        {:fallback, _reason} ->
          plan_local_compact_history(context)
      end
    end
  end

  defp plan_local_compact_history(%PlanContext{} = context, tail_rows_requested \\ nil) do
    %PlanContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      current_input: current_input,
      brain_context_pack: pack,
      request: request,
      runtime: runtime,
      total_tokens: total_tokens,
      threshold: threshold,
      native_state: native_state
    } = context

    visible_previous_response_id =
      if CompactionHistory.native_checkpoint?(native_state),
        do: CompactionHistory.previous_response_id_for(history, request)

    history =
      CompactionHistory.local_checkpoint_history(conversation_id, history, request, native_state)

    context = %{context | history: history}

    with {:ok, candidate} <-
           CompactionCandidate.for_history(
             subject_uid,
             history,
             current_input,
             CompactionPolicy.retained_tail_budget_tokens(threshold, pack),
             tail_rows_requested
           ),
         :ok <- ensure_worthwhile_prefix_yield(context, candidate, tail_rows_requested),
         candidate = %{candidate | brain_context_pack: pack},
         # The summary bypasses the quota but stays attributed to the Turn that needed it.
         {:ok, summary} <-
           CompactionSummarizer.summarize_candidate(subject_uid, candidate,
             request_context: UsageLedger.attribution(Map.get(runtime, "request_context"))
           ),
         :ok <-
           CompactionArtifacts.checkpoint_within_budget(
             candidate,
             summary,
             current_input,
             threshold
           ) do
      previous_response_id = "resp_#{candidate.anchor.id}"

      {:ok,
       history_plan(
         context,
         history,
         previous_response_id,
         %{
           artifact_attrs:
             CompactionArtifacts.artifact_attrs_for_candidate(
               subject_uid,
               conversation_id,
               candidate,
               summary
             ),
           checkpoint_metadata:
             CompactionArtifacts.checkpoint_metadata(
               request,
               CompactionArtifacts.compaction_metadata(
                 summary,
                 candidate,
                 total_tokens,
                 checkpoint_auto_flags(context)
               ),
               context.issuer
             )
         },
         %{
           "auto_compaction" =>
             put_trigger(context, %{
               "history_usage_tokens_before" => total_tokens,
               "token_threshold" => threshold.tokens,
               "context_length" => threshold.context_length,
               "threshold" => threshold.threshold,
               "max_threshold_tokens" => threshold.max_threshold_tokens,
               "summarizer_model" => summary.model,
               "usage" => summary.usage
             })
         }
       )}
    else
      {:suppress_prefix, cooldown_metadata} ->
        {:ok,
         unchanged_with_metadata(context, %{"auto_compaction_cooldown" => cooldown_metadata})}

      {:error, :invalid_history_projection} = error ->
        error

      {:error, reason} ->
        overflow_fallback(context, reason)
    end
    |> preserve_visible_anchor(visible_previous_response_id)
  end

  defp ensure_worthwhile_prefix_yield(
         %PlanContext{
           trigger: trigger,
           synthetic_usage?: false,
           projected_tokens: projected_tokens,
           wire_ratio: wire_ratio,
           threshold: threshold
         },
         candidate,
         nil
       )
       when trigger in [:history_usage, :preflight_delta] do
    if threshold.tokens >= @real_window_floor_tokens and
         projected_tokens <= hard_context_ceiling_tokens(threshold) do
      prefix_items = CompactionHistory.messages_to_items(candidate.prefix)

      prefix_tokens =
        if prefix_items == [],
          do: 0,
          else: round(CompactionHistory.items_token_estimate(prefix_items) * wire_ratio)

      min_prefix_tokens =
        min(
          floor(threshold.tokens * @hysteresis_window_share),
          @min_prefix_yield_cap_tokens
        )

      if prefix_tokens < min_prefix_tokens do
        {:suppress_prefix,
         %{
           "reason" => "insufficient_prefix_yield",
           "prefix_estimated_tokens" => prefix_tokens,
           "min_prefix_tokens" => min_prefix_tokens,
           "projected_input_tokens" => projected_tokens,
           "wire_ratio" => wire_ratio
         }}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp ensure_worthwhile_prefix_yield(_context, _candidate, _tail_rows_requested), do: :ok

  defp checkpoint_auto_flags(%PlanContext{projected_tokens: projected, total_tokens: total})
       when projected > total do
    %{"auto" => true, "projected_tokens_before" => projected}
  end

  defp checkpoint_auto_flags(%PlanContext{}), do: %{"auto" => true}

  defp upstream_history_plan(%PlanContext{} = context, upstream) do
    %PlanContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      request: request,
      total_tokens: total_tokens,
      threshold: threshold
    } = context

    previous_response_id = CompactionHistory.previous_response_id_for(history, request)

    with {:ok, artifact_attrs} <-
           CompactionArtifacts.with_upstream_pack(
             CompactionArtifacts.upstream_artifact_attrs(subject_uid, conversation_id, upstream),
             context.brain_context_pack,
             context.current_input,
             threshold
           ) do
      {:ok,
       history_plan(
         context,
         history,
         previous_response_id,
         %{
           artifact_attrs: artifact_attrs,
           checkpoint_metadata:
             CompactionArtifacts.checkpoint_metadata(
               request,
               %{
                 "auto" => true,
                 "source" => "upstream",
                 "history_usage_tokens_before" => total_tokens
               },
               context.issuer
             )
         },
         %{
           "auto_compaction" =>
             put_trigger(context, %{
               "source" => "upstream",
               "history_usage_tokens_before" => total_tokens,
               "token_threshold" => threshold.tokens,
               "context_length" => threshold.context_length,
               "threshold" => threshold.threshold,
               "max_threshold_tokens" => threshold.max_threshold_tokens,
               "usage" => upstream.usage
             })
         }
       )}
    else
      {:error, reason} -> overflow_fallback(context, reason)
    end
  end

  defp preserve_visible_anchor({:ok, plan}, previous_response_id)
       when is_binary(previous_response_id) do
    {:ok,
     plan
     |> Map.put(:previous_response_id, previous_response_id)
     |> Map.put(:expected_previous_response_id, previous_response_id)}
  end

  defp preserve_visible_anchor(result, _previous_response_id), do: result

  defp unchanged(%PlanContext{} = context), do: unchanged_with_metadata(context, %{})

  defp unchanged_with_metadata(
         %PlanContext{history: history, request: request} = context,
         metadata
       ) do
    restored_context = %{context | injection: context.original_injection || context.injection}

    history_plan(
      restored_context,
      history,
      CompactionHistory.previous_response_id_for(history, request),
      nil,
      metadata
    )
  end

  defp history_plan(
         %PlanContext{} = context,
         history,
         previous_response_id,
         compaction,
         run_metadata
       ) do
    %{
      history: history,
      current_input: context.current_input,
      injection: context.injection,
      previous_response_id: previous_response_id,
      expected_previous_response_id: previous_response_id,
      compaction: compaction,
      run_metadata: run_metadata
    }
  end

  # The token counts alone would read as a checkpoint written below its
  # trigger, so the metadata names non-standard triggers and preflight deltas.
  defp put_trigger(%PlanContext{} = context, metadata) do
    metadata
    |> maybe_put_trigger_name(context.trigger)
    |> maybe_put_projection_metadata(context)
  end

  defp maybe_put_trigger_name(metadata, :provider_history),
    do: Map.put(metadata, "trigger", "provider_history")

  defp maybe_put_trigger_name(metadata, :preflight_delta),
    do: Map.put(metadata, "trigger", "preflight_delta")

  defp maybe_put_trigger_name(metadata, _trigger), do: metadata

  defp maybe_put_projection_metadata(
         metadata,
         %PlanContext{
           projected_tokens: projected_tokens,
           delta_tokens: delta_tokens,
           wire_ratio: wire_ratio
         }
       )
       when delta_tokens > 0 do
    metadata
    |> Map.put("projected_input_tokens", projected_tokens)
    |> Map.put("preflight_delta_tokens", delta_tokens)
    |> Map.put("wire_ratio", wire_ratio)
  end

  defp maybe_put_projection_metadata(metadata, _context), do: metadata

  defp overflow_fallback(%PlanContext{required?: false}, reason), do: {:error, reason}

  defp overflow_fallback(%PlanContext{} = context, reason) do
    overflow_tokens = max(context.total_tokens, context.projected_tokens)

    if auto_truncation?(context.request) do
      truncate_history(context, reason)
    else
      {:error, context_overflow(overflow_tokens, reason, "disabled", context.threshold)}
    end
  end

  defp truncate_history(%PlanContext{} = context, reason) do
    %PlanContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      current_input: current_input,
      brain_context_pack: pack,
      request: request,
      total_tokens: total_tokens,
      threshold: threshold
    } = context

    with {:ok, truncated_history} <-
           CompactionCandidate.truncate_history_to_stable_tail(history, current_input),
         {:ok, retained_items} <-
           CompactionHistory.history_items_for_artifact(subject_uid, truncated_history),
         {:ok, history_items} <-
           CompactionHistory.history_items_for_artifact(subject_uid, history),
         {:ok, retained_client_tool_search} <-
           CompactionRetention.collect_client_tool_search(
             history_items ++ CompactionHistory.input_items(current_input),
             retained_items ++ CompactionHistory.input_items(current_input)
           ),
         :ok <-
           CompactionArtifacts.checkpoint_items_within_budget(
             pack ++
               [CompactionArtifacts.compaction_summary_item(@stable_tail_summary)] ++
               retained_client_tool_search ++
               retained_items ++ CompactionHistory.input_items(current_input),
             threshold
           ) do
      retained_items = retained_client_tool_search ++ retained_items
      previous_response_id = CompactionHistory.previous_response_id_for(history, request)

      auto_truncation =
        auto_truncation_metadata(
          history,
          truncated_history,
          total_tokens,
          reason,
          threshold
        )

      {:ok,
       history_plan(
         context,
         truncated_history,
         previous_response_id,
         %{
           artifact_attrs: %{
             subject_uid: subject_uid,
             conversation_id: conversation_id,
             summary_text: @stable_tail_summary,
             brain_context_pack: pack,
             retained_items: retained_items,
             retained_user_originals: [],
             retention: %{
               "strategy" => "stable_tail",
               "requested" => CompactionPolicy.tail_rows(),
               "actual" => length(truncated_history),
               "user_message_count" => 0
             },
             usage: %{}
           },
           checkpoint_metadata:
             CompactionArtifacts.checkpoint_metadata(
               request,
               %{
                 "auto" => true,
                 "strategy" => "stable_tail",
                 "auto_truncation" => auto_truncation
               },
               context.issuer
             )
         },
         %{
           "truncation" => "auto",
           "auto_truncation" => auto_truncation
         }
       )}
    else
      {:error, failure_reason} ->
        {:error, context_overflow(total_tokens, failure_reason, "auto", threshold)}
    end
  end

  defp auto_truncation_metadata(
         history,
         truncated_history,
         total_tokens,
         reason,
         threshold
       ) do
    dropped_opaque_messages =
      CompactionHistory.dropped_opaque_messages(history, truncated_history)

    %{
      "reason" => overflow_reason(reason),
      "history_usage_tokens_before" => total_tokens,
      "token_threshold" => threshold.tokens,
      "context_length" => threshold.context_length,
      "threshold" => threshold.threshold,
      "max_threshold_tokens" => threshold.max_threshold_tokens,
      "dropped_message_count" => length(history) - length(truncated_history),
      "retained_message_count" => length(truncated_history)
    }
    |> CompactionHistory.put_nonempty("dropped_opaque_messages", dropped_opaque_messages)
    |> maybe_put_count("dropped_opaque_message_count", dropped_opaque_messages)
  end

  defp auto_truncation?(%{"truncation" => "auto"}), do: true
  defp auto_truncation?(_request), do: false

  defp context_overflow(total_tokens, reason, truncation, threshold) do
    {:context_overflow,
     %{
       history_usage_tokens: total_tokens,
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

  defp maybe_put_count(map, _key, []), do: map
  defp maybe_put_count(map, key, values), do: Map.put(map, key, length(values))
end
