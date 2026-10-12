defmodule Ankole.AIGateway.Compaction do
  alias Ankole.AIGateway.ResponseChain

  @moduledoc """
  AIGateway-owned automatic history compaction.

  Automatic token decisions use the newest provider-returned usage stored on
  the visible AIGateway history. Each usage value is a cumulative snapshot, not
  an amount to add to earlier Response usage. AIGateway does not estimate token
  counts from content.
  """

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CompactionSummarizer
  alias Ankole.AIGateway.CompactionRetention
  alias Ankole.AIGateway.UpstreamCompaction
  alias Ankole.AIGateway.Schemas.Message

  alias Ankole.AIGateway.{CompactionCandidate}
  import Ankole.AIGateway.CompactionPolicy, only: [retained_tail_budget_tokens: 2, tail_rows: 0]

  import Ankole.AIGateway.CompactionArtifacts,
    only: [
      compaction_summary_item: 1,
      checkpoint_items_within_budget: 2,
      checkpoint_pack: 5,
      with_upstream_pack: 4,
      upstream_artifact_attrs: 3,
      artifact_attrs_for_candidate: 4,
      compaction_metadata: 4,
      checkpoint_metadata: 3,
      checkpoint_within_budget: 4
    ]

  import Ankole.AIGateway.CompactionHistory,
    only: [
      native_checkpoint_state: 3,
      native_checkpoint?: 1,
      force_local_checkpoint?: 2,
      raw_history: 3,
      previous_response_id_for: 2,
      dropped_opaque_messages: 2,
      truncate_history_to_stable_tail: 2,
      history_usage_tokens: 1,
      put_nonempty: 3,
      input_items: 1,
      history_items_for_artifact: 2,
      messages_to_items: 1
    ]

  @stable_tail_summary "Earlier conversation history was omitted because it exceeded the active context budget."

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
    defstruct @enforce_keys
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
        runtime \\ %{}
      )
      when is_list(history) and is_list(current_input) and is_map(request) do
    total_tokens = history_usage_tokens(history)
    threshold = Ankole.AIGateway.CompactionPolicy.threshold_spec(runtime, request)
    upstream_compaction? = Ankole.AIGateway.CompactionPolicy.upstream_compaction?()

    with {:ok, native_state} <- native_checkpoint_state(subject_uid, history, runtime) do
      context = %PlanContext{
        subject_uid: subject_uid,
        conversation_id: conversation_id,
        history: history,
        current_input: current_input,
        injection: injection,
        brain_context_pack: [],
        request: request,
        total_tokens: total_tokens,
        threshold: threshold,
        runtime: runtime,
        issuer: Map.get(runtime, "provider_id"),
        native_state: native_state,
        upstream_compaction?: upstream_compaction?
      }

      cond do
        force_local_checkpoint?(native_state, upstream_compaction?) ->
          visible_previous_response_id = previous_response_id_for(history, request)

          context =
            %{context | history: raw_history(conversation_id, history, request)}
            |> prepare_checkpoint_context()

          context
          |> plan_local_compact_history()
          |> preserve_visible_anchor(visible_previous_response_id)

        total_tokens <= threshold.tokens ->
          {:ok, unchanged(context)}

        true ->
          context |> prepare_checkpoint_context() |> plan_compact_history()
      end
    end
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
        runtime
      )
      when is_binary(previous_response_id) and is_list(current_input) and is_map(request) and
             is_map(runtime) do
    history =
      conversation_id
      |> ResponseChain.expand_history(
        previous_response_id: previous_response_id,
        stop_at_checkpoint: false
      )
      |> Enum.reject(&(&1.type == "checkpoint"))

    recovery_tail_rows = min(tail_rows(), max(length(history) - 1, 0))

    context = %PlanContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      current_input: current_input,
      injection: injection,
      brain_context_pack: [],
      request: request,
      total_tokens: history_usage_tokens(history),
      threshold: Ankole.AIGateway.CompactionPolicy.threshold_spec(runtime, request),
      runtime: runtime,
      issuer: nil,
      native_state: :none,
      upstream_compaction?: false
    }

    context
    |> prepare_checkpoint_context()
    |> plan_local_compact_history(recovery_tail_rows)
  end

  defp prepare_checkpoint_context(%PlanContext{} = context) do
    input = context.current_input
    injection = Map.drop(context.injection, ~w(brain_context_pack brain_context_pack_claimed))

    pack =
      checkpoint_pack(
        context.subject_uid,
        context.conversation_id,
        context.request,
        input,
        context.history
      )

    %{context | current_input: input, injection: injection, brain_context_pack: pack}
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
      conversation_id: conversation_id,
      history: history,
      request: request,
      runtime: runtime,
      native_state: native_state,
      upstream_compaction?: upstream_compaction?
    } = context

    with {:ok, input} <- history_items_for_artifact(subject_uid, history),
         {:ok, input} <- CompactionArtifacts.resolve_input_handles(subject_uid, input) do
      case UpstreamCompaction.compact(runtime, input, request,
             enabled?: upstream_compaction?,
             subject_uid: subject_uid
           ) do
        {:ok, upstream} ->
          upstream_history_plan(context, upstream)

        {:fallback, _reason} ->
          visible_previous_response_id = previous_response_id_for(history, request)

          context =
            if native_checkpoint?(native_state),
              do: %{context | history: raw_history(conversation_id, history, request)},
              else: context

          context
          |> plan_local_compact_history()
          |> preserve_visible_anchor(
            if(native_checkpoint?(native_state),
              do: visible_previous_response_id,
              else: nil
            )
          )
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
      total_tokens: total_tokens,
      threshold: threshold
    } = context

    with {:ok, candidate} <-
           CompactionCandidate.for_history(
             subject_uid,
             history,
             current_input,
             retained_tail_budget_tokens(threshold, pack),
             tail_rows_requested
           ),
         candidate = %{candidate | brain_context_pack: pack},
         {:ok, summary} <- summarize_candidate(subject_uid, candidate),
         :ok <- checkpoint_within_budget(candidate, summary, current_input, threshold) do
      previous_response_id = "resp_#{candidate.anchor.id}"

      {:ok,
       history_plan(
         context,
         history,
         previous_response_id,
         %{
           artifact_attrs:
             artifact_attrs_for_candidate(
               subject_uid,
               conversation_id,
               candidate,
               summary
             ),
           checkpoint_metadata:
             checkpoint_metadata(
               request,
               compaction_metadata(summary, candidate, total_tokens, %{"auto" => true}),
               context.issuer
             )
         },
         %{
           "auto_compaction" => %{
             "history_usage_tokens_before" => total_tokens,
             "token_threshold" => threshold.tokens,
             "context_length" => threshold.context_length,
             "threshold" => threshold.threshold,
             "max_threshold_tokens" => threshold.max_threshold_tokens,
             "summarizer_model" => summary.model,
             "usage" => summary.usage
           }
         }
       )}
    else
      {:error, reason} -> overflow_fallback(context, reason)
    end
  end

  defp upstream_history_plan(%PlanContext{} = context, upstream) do
    %PlanContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      request: request,
      total_tokens: total_tokens,
      threshold: threshold
    } = context

    previous_response_id = previous_response_id_for(history, request)

    with {:ok, artifact_attrs} <-
           with_upstream_pack(
             upstream_artifact_attrs(subject_uid, conversation_id, upstream),
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
             checkpoint_metadata(
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
           "auto_compaction" => %{
             "source" => "upstream",
             "history_usage_tokens_before" => total_tokens,
             "token_threshold" => threshold.tokens,
             "context_length" => threshold.context_length,
             "threshold" => threshold.threshold,
             "max_threshold_tokens" => threshold.max_threshold_tokens,
             "usage" => upstream.usage
           }
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

  defp unchanged(%PlanContext{history: history, request: request} = context) do
    history_plan(context, history, previous_response_id_for(history, request), nil, %{})
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

  defp overflow_fallback(%PlanContext{} = context, reason) do
    if auto_truncation?(context.request) do
      truncate_history(context, reason)
    else
      {:error, context_overflow(context.total_tokens, reason, "disabled", context.threshold)}
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
           truncate_history_to_stable_tail(history, current_input),
         {:ok, retained_items} <- history_items_for_artifact(subject_uid, truncated_history),
         {:ok, history_items} <- history_items_for_artifact(subject_uid, history),
         {:ok, retained_client_tool_search} <-
           CompactionRetention.collect_client_tool_search(
             history_items ++ input_items(current_input),
             retained_items ++ input_items(current_input)
           ),
         :ok <-
           checkpoint_items_within_budget(
             pack ++
               [compaction_summary_item(@stable_tail_summary)] ++
               retained_client_tool_search ++
               retained_items ++ input_items(current_input),
             threshold
           ) do
      retained_items = retained_client_tool_search ++ retained_items
      previous_response_id = previous_response_id_for(history, request)

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
               "requested" => tail_rows(),
               "actual" => length(truncated_history),
               "user_message_count" => 0
             },
             usage: %{}
           },
           checkpoint_metadata:
             checkpoint_metadata(
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
    dropped_opaque_messages = dropped_opaque_messages(history, truncated_history)

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
    |> put_nonempty("dropped_opaque_messages", dropped_opaque_messages)
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

  # `identity` names the Agent-token request that asked for this compaction.
  # Automatic compaction passes none and runs on behalf of the control plane.
  defp summarize_candidate(subject_uid, candidate, identity \\ []) do
    CompactionSummarizer.summarize(
      subject_uid,
      messages_to_items(candidate.prefix),
      candidate.previous_chat_history,
      [recent_items: candidate.recent_items] ++ identity
    )
  end

  defp maybe_put_count(map, _key, []), do: map
  defp maybe_put_count(map, key, values), do: Map.put(map, key, length(values))
end
