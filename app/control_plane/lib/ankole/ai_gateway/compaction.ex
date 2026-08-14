defmodule Ankole.AIGateway.Compaction do
  @moduledoc """
  AIGateway-owned automatic history compaction.

  Automatic token decisions use the newest provider-returned usage stored on
  the visible AIGateway history. Each usage value is a cumulative snapshot, not
  an amount to add to earlier Response usage. AIGateway does not estimate token
  counts from content.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CompactionPrompt
  alias Ankole.AIGateway.CompactionRender
  alias Ankole.AIGateway.CompactionRetention
  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.UpstreamCompaction
  alias Ankole.AIGateway.Schemas.Message

  @config_key "ai_gateway.compaction"
  @default_threshold_percent 0.50
  @default_max_threshold_tokens 100_000
  @default_context_length 256_000
  @minimum_context_length 64_000
  @small_context_trigger_ratio 0.85
  @default_tail_rows 2
  @summarizer_max_output_tokens 8_192
  @summarizer_retry_max_output_tokens 16_384
  @checkpoint_overhead_tokens 1_000
  @brain_pre_compaction_nudge_marker "ankole.brain.pre_compaction_nudge.v1"
  @stable_tail_summary "Earlier conversation history was omitted because it exceeded the active context budget."
  @opaque_ref_keys ~w(agent_computer_path blob_ref content_type file_id file_url filename id image_url media_type mime_type name path provider_file_id provider_ref provider_uri storage_ref uri url)
  @max_ref_chars 512
  @type result :: %{
          history: [Message.t()],
          previous_response_id: binary() | nil,
          compaction: Message.t() | nil,
          run_metadata: map()
        }

  @type history_plan :: %{
          history: [Message.t()],
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

  @default_config %{
    "threshold" => @default_threshold_percent,
    "max_threshold_tokens" => @default_max_threshold_tokens,
    "tail_rows" => @default_tail_rows,
    "user_message_budget_tokens" => 20_000,
    "prefer_upstream" => false
  }

  @type threshold_spec :: %{
          tokens: pos_integer(),
          context_length: pos_integer(),
          effective_context_length: pos_integer(),
          threshold: float(),
          max_threshold_tokens: pos_integer(),
          max_output_tokens: pos_integer() | nil
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
      :request,
      :total_tokens,
      :threshold,
      :runtime,
      :native_state,
      :prefer_upstream?
    ]
    defstruct @enforce_keys
  end

  defmodule ManualContext do
    @moduledoc false
    @enforce_keys [
      :subject_uid,
      :conversation_id,
      :history,
      :request,
      :total_tokens,
      :runtime,
      :native_state,
      :visible_previous_response_id,
      :prefer_upstream?
    ]
    defstruct @enforce_keys
  end

  @spec config_definition() :: Definition.t()
  def config_definition do
    AppConfigure.define(
      key: @config_key,
      encrypted: false,
      schema: config_schema(),
      default_value: @default_config,
      description:
        "AIGateway history compaction settings. `threshold` is a ratio of the model input context; `max_threshold_tokens` caps that computed trigger; `prefer_upstream` tries a Responses Provider's standalone compact operation before local compaction and enables Codex v2 only for new ChatGPT Subscription Jobs."
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

  @doc "Returns whether new compaction attempts prefer the provider operation."
  @spec prefer_upstream?() :: boolean()
  def prefer_upstream?, do: Map.get(config(), "prefer_upstream", false)

  @doc false
  @spec prefer_upstream_in_tx?(module()) :: boolean()
  def prefer_upstream_in_tx?(repo) when is_atom(repo) do
    with :ok <- ensure_registered(),
         {:ok, config} <- AppConfigure.get_in_tx(repo, config_definition()) do
      Map.get(config, "prefer_upstream", false)
    else
      _reason -> false
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
        subject_uid,
        conversation_id,
        history,
        current_input,
        request,
        runtime \\ %{}
      )
      when is_list(history) and is_list(current_input) and is_map(request) do
    with {:ok, plan} <-
           maybe_plan_history(
             subject_uid,
             conversation_id,
             history,
             current_input,
             request,
             runtime
           ) do
      materialize_history_plan(subject_uid, conversation_id, plan)
    end
  end

  @doc false
  @spec maybe_plan_history(String.t(), binary(), [Message.t()], [map()], map(), map()) ::
          {:ok, history_plan()} | {:error, term()}
  def maybe_plan_history(
        subject_uid,
        conversation_id,
        history,
        current_input,
        request,
        runtime \\ %{}
      )
      when is_list(history) and is_list(current_input) and is_map(request) do
    total_tokens = history_usage_tokens(history)
    threshold = threshold_spec(runtime, request)
    prefer_upstream? = prefer_upstream?()

    with {:ok, native_state} <- native_checkpoint_state(subject_uid, history, runtime) do
      context = %PlanContext{
        subject_uid: subject_uid,
        conversation_id: conversation_id,
        history: history,
        current_input: current_input,
        request: request,
        total_tokens: total_tokens,
        threshold: threshold,
        runtime: runtime,
        native_state: native_state,
        prefer_upstream?: prefer_upstream?
      }

      cond do
        force_local_checkpoint?(native_state, prefer_upstream?) ->
          visible_previous_response_id = previous_response_id_for(history, request)
          context = %{context | history: raw_history(conversation_id, history, request)}

          context
          |> plan_local_compact_history()
          |> preserve_visible_anchor(visible_previous_response_id)

        total_tokens <= threshold.tokens ->
          {:ok, unchanged(history, request)}

        brain_pre_compaction_nudge_due?(history, total_tokens, threshold) ->
          {:ok, brain_pre_compaction_nudge(history, request, total_tokens, threshold)}

        true ->
          plan_compact_history(context)
      end
    end
  end

  @doc """
  Adds the one-time Brain pre-compaction nudge to normal model input when due.
  """
  @spec maybe_inject_brain_pre_compaction_nudge([map()], map()) :: [map()]
  def maybe_inject_brain_pre_compaction_nudge(current_input, %{
        "brain_pre_compaction_nudge" => %{"status" => "due"}
      })
      when is_list(current_input) do
    [brain_pre_compaction_nudge_input() | current_input]
  end

  def maybe_inject_brain_pre_compaction_nudge(current_input, _run_metadata)
      when is_list(current_input),
      do: current_input

  @doc false
  @spec put_checkpoint_response_id(map(), binary() | nil) :: map()
  def put_checkpoint_response_id(%{"auto_compaction" => %{} = metadata} = run_metadata, id) do
    Map.put(run_metadata, "auto_compaction", Map.put(metadata, "response_id", id))
  end

  def put_checkpoint_response_id(%{"auto_truncation" => %{} = metadata} = run_metadata, id) do
    Map.put(run_metadata, "auto_truncation", Map.put(metadata, "response_id", id))
  end

  def put_checkpoint_response_id(run_metadata, _id), do: run_metadata

  @doc """
  Forces one manual compaction for a conversation's current visible chain.

  This is the control-plane `/compress` path. It reuses the same candidate and
  summarizer logic as automatic compaction, but it does not depend on the
  recorded history usage crossing the automatic threshold.
  """
  @spec compact_conversation(String.t(), binary(), map()) ::
          {:ok,
           %{compaction: Message.t(), previous_response_id: binary(), history: [Message.t()]}}
          | {:error, term()}
  def compact_conversation(subject_uid, conversation_id, request \\ %{}) when is_map(request) do
    history = StatefulResponses.expand_history(conversation_id)
    total_tokens = history_usage_tokens(history)
    visible_previous_response_id = previous_response_id_for(history, request)
    prefer_upstream? = prefer_upstream?()

    with {:ok, runtime} <-
           ResponsesPreparation.resolve_runtime(subject_uid, %{"model" => "primary"}),
         {:ok, native_state} <- native_checkpoint_state(subject_uid, history, runtime) do
      history =
        if force_local_checkpoint?(native_state, prefer_upstream?),
          do: raw_history(conversation_id, history, request),
          else: history

      compact_conversation_history(%ManualContext{
        subject_uid: subject_uid,
        conversation_id: conversation_id,
        history: history,
        request: request,
        total_tokens: total_tokens,
        runtime: runtime,
        native_state: native_state,
        visible_previous_response_id: visible_previous_response_id,
        prefer_upstream?: prefer_upstream?
      })
    end
  end

  @doc """
  Creates one OpenResponses compaction resource.

  The artifact is always persisted. `store=true` additionally creates a
  checkpoint response row so clients may continue with `previous_response_id`.
  """
  @spec compact_response(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def compact_response(subject_uid, request) when is_map(request) do
    request = MapUtils.normalize_request_keys(request)
    prefer_upstream? = prefer_upstream?()

    with {:ok, _model} <- standalone_model(request),
         {:ok, input} <- standalone_input(request),
         {:ok, resolved_input} <- CompactionArtifacts.resolve_input_handles(subject_uid, input),
         {:ok, store_context} <- compact_store_context(subject_uid, request),
         {:ok, runtime} <-
           compact_response_runtime(subject_uid, request, prefer_upstream?) do
      compact_standalone(
        subject_uid,
        request,
        input,
        resolved_input,
        store_context,
        runtime,
        prefer_upstream?
      )
    end
  end

  def compact_response(_subject_uid, _request), do: {:error, :invalid_request_body}

  defp plan_compact_history(%PlanContext{} = context) do
    %PlanContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      request: request,
      runtime: runtime,
      native_state: native_state,
      prefer_upstream?: prefer_upstream?
    } = context

    with {:ok, input} <- history_items_for_artifact(subject_uid, history),
         {:ok, input} <- CompactionArtifacts.resolve_input_handles(subject_uid, input) do
      case UpstreamCompaction.compact(runtime, input, request,
             enabled?: prefer_upstream?,
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

  defp plan_local_compact_history(%PlanContext{} = context) do
    %PlanContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      current_input: current_input,
      request: request,
      total_tokens: total_tokens,
      threshold: threshold
    } = context

    with {:ok, candidate} <-
           compaction_candidate(
             subject_uid,
             history,
             current_input,
             retained_tail_budget_tokens(threshold)
           ),
         {:ok, summary} <- summarize_candidate(subject_uid, candidate, request),
         :ok <- checkpoint_within_budget(candidate, summary, current_input, threshold) do
      previous_response_id = "resp_#{candidate.anchor.id}"

      {:ok,
       %{
         history: history,
         previous_response_id: previous_response_id,
         expected_previous_response_id: previous_response_id,
         compaction: %{
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
               compaction_metadata(summary, candidate, total_tokens, %{"auto" => true})
             )
         },
         run_metadata: %{
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
       }}
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

    {:ok,
     %{
       history: history,
       previous_response_id: previous_response_id,
       expected_previous_response_id: previous_response_id,
       compaction: %{
         artifact_attrs: upstream_artifact_attrs(subject_uid, conversation_id, upstream),
         checkpoint_metadata:
           checkpoint_metadata(request, %{
             "auto" => true,
             "source" => "upstream",
             "history_usage_tokens_before" => total_tokens
           })
       },
       run_metadata: %{
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
     }}
  end

  defp compact_conversation_history(%ManualContext{} = context) do
    %ManualContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      request: request,
      runtime: runtime,
      native_state: native_state,
      prefer_upstream?: prefer_upstream?
    } = context

    if force_local_checkpoint?(native_state, prefer_upstream?) do
      compact_conversation_locally(context)
    else
      with {:ok, input} <- history_items_for_artifact(subject_uid, history),
           {:ok, input} <- CompactionArtifacts.resolve_input_handles(subject_uid, input) do
        case UpstreamCompaction.compact(runtime, input, request,
               enabled?: prefer_upstream?,
               subject_uid: subject_uid
             ) do
          {:ok, upstream} ->
            create_manual_upstream_checkpoint(context, upstream)

          {:fallback, _reason} ->
            context =
              if native_checkpoint?(native_state),
                do: %{context | history: raw_history(conversation_id, history, request)},
                else: context

            compact_conversation_locally(context)
        end
      end
    end
  end

  defp compact_conversation_locally(%ManualContext{} = context) do
    %ManualContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      request: request,
      total_tokens: total_tokens,
      visible_previous_response_id: visible_previous_response_id
    } = context

    with {:ok, candidate} <- compaction_candidate(subject_uid, history, []),
         {:ok, summary} <- summarize_candidate(subject_uid, candidate, request),
         {:ok, artifact} <-
           create_artifact_for_candidate(subject_uid, conversation_id, candidate, summary),
         {:ok, checkpoint} <-
           StatefulResponses.create_compaction_checkpoint(%{
             subject_uid: subject_uid,
             previous_response_id: visible_previous_response_id,
             artifact: artifact,
             metadata:
               checkpoint_metadata(
                 request,
                 compaction_metadata(summary, candidate, total_tokens, %{
                   "auto" => false,
                   "manual" => true
                 })
               )
           }) do
      manual_checkpoint_result(conversation_id, checkpoint)
    end
  end

  defp create_manual_upstream_checkpoint(%ManualContext{} = context, upstream) do
    %ManualContext{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      request: request,
      visible_previous_response_id: previous_response_id
    } = context

    with {:ok, artifact} <-
           CompactionArtifacts.insert_artifact(
             upstream_artifact_attrs(subject_uid, conversation_id, upstream)
           ),
         {:ok, checkpoint} <-
           StatefulResponses.create_compaction_checkpoint(%{
             subject_uid: subject_uid,
             previous_response_id: previous_response_id,
             artifact: artifact,
             metadata:
               checkpoint_metadata(request, %{
                 "auto" => false,
                 "manual" => true,
                 "source" => "upstream"
               })
           }) do
      manual_checkpoint_result(conversation_id, checkpoint)
    end
  end

  defp manual_checkpoint_result(conversation_id, checkpoint) do
    previous_response_id = "resp_#{checkpoint.id}"

    {:ok,
     %{
       compaction: checkpoint,
       previous_response_id: previous_response_id,
       history:
         StatefulResponses.expand_history(conversation_id,
           previous_response_id: previous_response_id
         )
     }}
  end

  defp compact_standalone(
         subject_uid,
         request,
         original_input,
         resolved_input,
         store_context,
         runtime,
         prefer_upstream?
       ) do
    case UpstreamCompaction.compact(runtime, resolved_input, request,
           enabled?: prefer_upstream?,
           subject_uid: subject_uid
         ) do
      {:ok, upstream} ->
        with {:ok, artifact} <-
               CompactionArtifacts.insert_artifact(
                 upstream_artifact_attrs(subject_uid, store_context.conversation_id, upstream)
               ),
             {:ok, ankole_extension} <-
               maybe_store_compaction_checkpoint(
                 subject_uid,
                 request,
                 store_context,
                 artifact
               ) do
          {:ok, CompactionArtifacts.response_body(artifact, ankole: ankole_extension)}
        end

      {:fallback, _reason} ->
        if UpstreamCompaction.opaque_input?(resolved_input) do
          {:error, :opaque_compaction_fallback_unavailable}
        else
          compact_standalone_locally(
            subject_uid,
            request,
            original_input,
            resolved_input,
            store_context
          )
        end
    end
  end

  defp compact_standalone_locally(
         subject_uid,
         request,
         original_input,
         resolved_input,
         store_context
       ) do
    with {:ok, candidate} <-
           standalone_compaction_candidate(subject_uid, original_input, resolved_input),
         {:ok, summary} <- summarize_standalone(subject_uid, candidate, request),
         {:ok, artifact} <-
           create_standalone_artifact(subject_uid, store_context, candidate, summary),
         {:ok, ankole_extension} <-
           maybe_store_compaction_checkpoint(subject_uid, request, store_context, artifact) do
      {:ok, CompactionArtifacts.response_body(artifact, ankole: ankole_extension)}
    end
  end

  defp upstream_artifact_attrs(subject_uid, conversation_id, upstream) do
    %{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      source: :upstream,
      binding: upstream.binding,
      output: upstream.output,
      usage: upstream.usage
    }
  end

  defp native_checkpoint_state(subject_uid, history, runtime) do
    case Enum.find(Enum.reverse(history), &(&1.type == "checkpoint")) do
      nil ->
        {:ok, :none}

      %Message{} = checkpoint ->
        with {:ok, content} <- CompactionArtifacts.content_for_checkpoint(subject_uid, checkpoint) do
          case content do
            %{"version" => 3, "source" => "upstream", "binding" => binding}
            when is_map(binding) ->
              state =
                if UpstreamCompaction.binding_matches?(binding, runtime),
                  do: :matching,
                  else: :mismatch

              {:ok, {:native, state}}

            %{"version" => 2} ->
              {:ok, :none}

            _invalid ->
              {:error, :invalid_compaction_handle}
          end
        end
    end
  end

  defp native_checkpoint?({:native, _state}), do: true
  defp native_checkpoint?(_state), do: false

  defp force_local_checkpoint?({:native, :mismatch}, _prefer_upstream?), do: true
  defp force_local_checkpoint?({:native, :matching}, prefer_upstream?), do: not prefer_upstream?
  defp force_local_checkpoint?(_state, _prefer_upstream?), do: false

  defp raw_history(conversation_id, history, request) do
    case previous_response_id_for(history, request) do
      previous_response_id when is_binary(previous_response_id) ->
        conversation_id
        |> StatefulResponses.expand_history(
          previous_response_id: previous_response_id,
          stop_at_checkpoint: false
        )
        |> Enum.reject(&(&1.type == "checkpoint"))

      _no_anchor ->
        []
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

  defp materialize_history_plan(_subject_uid, _conversation_id, %{compaction: nil} = plan) do
    {:ok, Map.delete(plan, :expected_previous_response_id)}
  end

  defp materialize_history_plan(
         subject_uid,
         conversation_id,
         %{
           previous_response_id: previous_response_id,
           compaction: %{
             artifact_attrs: artifact_attrs,
             checkpoint_metadata: checkpoint_metadata
           }
         } = plan
       ) do
    with {:ok, artifact} <- CompactionArtifacts.insert_artifact(artifact_attrs),
         {:ok, checkpoint} <-
           StatefulResponses.create_compaction_checkpoint(%{
             subject_uid: subject_uid,
             previous_response_id: previous_response_id,
             artifact: artifact,
             metadata: checkpoint_metadata
           }) do
      checkpoint_response_id = "resp_#{checkpoint.id}"

      {:ok,
       plan
       |> Map.put(
         :history,
         StatefulResponses.expand_history(conversation_id,
           previous_response_id: checkpoint_response_id
         )
       )
       |> Map.put(:previous_response_id, checkpoint_response_id)
       |> Map.put(:compaction, checkpoint)
       |> Map.update!(:run_metadata, fn run_metadata ->
         put_checkpoint_response_id(run_metadata, checkpoint_response_id)
       end)
       |> Map.delete(:expected_previous_response_id)}
    end
  end

  defp create_artifact_for_candidate(subject_uid, conversation_id, candidate, summary) do
    CompactionArtifacts.insert_artifact(
      artifact_attrs_for_candidate(subject_uid, conversation_id, candidate, summary)
    )
  end

  defp artifact_attrs_for_candidate(subject_uid, conversation_id, candidate, summary) do
    %{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      summary_text: summary.text,
      retained_items: messages_to_items(candidate.retained_tail),
      # The replayed originals may end with a still-unanswered clarify
      # call/output pair; "user_message_count" counts only user messages.
      retained_user_originals:
        candidate.retained_user_originals ++ candidate.retained_pending_clarify,
      retention: %{
        "strategy" => "tail_rows",
        "requested" => candidate.tail_rows_requested,
        "actual" => length(candidate.retained_tail),
        "user_budget_tokens" => user_message_budget_tokens(),
        "user_message_count" => length(candidate.retained_user_originals)
      },
      usage: summary.usage
    }
  end

  defp create_standalone_artifact(subject_uid, store_context, candidate, summary) do
    CompactionArtifacts.insert_artifact(%{
      subject_uid: subject_uid,
      conversation_id: store_context.conversation_id,
      summary_text: summary.text,
      retained_items: candidate.retained_tail,
      retained_user_originals:
        candidate.retained_user_originals ++ candidate.retained_pending_clarify,
      retention:
        %{
          "strategy" => "standalone_user_messages",
          "requested" => candidate.tail_rows_requested,
          "actual" => length(candidate.retained_tail),
          "user_budget_tokens" => user_message_budget_tokens(),
          "user_message_count" => length(candidate.retained_user_originals)
        }
        |> maybe_put(
          "previous_summary_discarded",
          if(candidate.previous_summary_discarded, do: true, else: nil)
        ),
      usage: summary.usage
    })
  end

  defp maybe_store_compaction_checkpoint(
         subject_uid,
         _request,
         %{store?: true} = store_context,
         artifact
       ) do
    with {:ok, checkpoint} <-
           StatefulResponses.create_compaction_checkpoint(%{
             subject_uid: subject_uid,
             conversation_id: store_context.conversation_id,
             previous_response_id: store_context.previous_response_id,
             artifact: artifact,
             metadata: %{"request_metadata" => store_context.metadata}
           }) do
      {:ok,
       %{
         "stored" => true,
         "response_id" => CompactionArtifacts.response_id(checkpoint.id),
         "conversation" => "conv_#{checkpoint.conversation_id}"
       }}
    end
  end

  defp maybe_store_compaction_checkpoint(_subject_uid, _request, _store_context, _artifact),
    do: {:ok, nil}

  defp compact_store_context(subject_uid, %{"store" => true} = request) do
    previous_response_id = Map.get(request, "previous_response_id")
    conversation_id = Map.get(request, "conversation")

    with :ok <- validate_compact_previous_response_id(previous_response_id),
         :ok <- validate_compact_conversation_id(conversation_id) do
      cond do
        nonempty_binary?(previous_response_id) ->
          case StatefulResponses.get_response_for_subject(subject_uid, previous_response_id) do
            {:ok, %Message{status: "complete"} = anchor} ->
              {:ok,
               %{
                 store?: true,
                 conversation_id: anchor.conversation_id,
                 previous_response_id: previous_response_id,
                 metadata: request_metadata(request)
               }}

            {:ok, %Message{}} ->
              {:error, :invalid_anchor}

            {:error, :not_found} ->
              {:error, :invalid_anchor}
          end

        nonempty_binary?(conversation_id) ->
          raw_conversation_id = decode_compact_conversation_id(conversation_id)

          with {:ok, conversation} <-
                 StatefulResponses.get_conversation_for_subject(subject_uid, raw_conversation_id) do
            {:ok,
             %{
               store?: true,
               conversation_id: conversation.id,
               previous_response_id: nil,
               metadata: request_metadata(request)
             }}
          end

        true ->
          with {:ok, conversation} <-
                 StatefulResponses.create_managed_stateful_responses_conversation(subject_uid,
                   metadata: request_metadata(request)
                 ) do
            {:ok,
             %{
               store?: true,
               conversation_id: conversation.id,
               previous_response_id: nil,
               metadata: request_metadata(request)
             }}
          end
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp compact_store_context(_subject_uid, request) do
    previous_response_id = Map.get(request, "previous_response_id")
    conversation_id = Map.get(request, "conversation")

    with :ok <- validate_compact_previous_response_id(previous_response_id),
         :ok <- validate_compact_conversation_id(conversation_id) do
      case {previous_response_id, conversation_id} do
        {nil, nil} ->
          {:ok, %{store?: false, conversation_id: nil, previous_response_id: nil, metadata: %{}}}

        {"", nil} ->
          {:ok, %{store?: false, conversation_id: nil, previous_response_id: nil, metadata: %{}}}

        {nil, ""} ->
          {:ok, %{store?: false, conversation_id: nil, previous_response_id: nil, metadata: %{}}}

        _anchor_without_store ->
          {:error, :compact_store_required}
      end
    end
  end

  defp unchanged(history, request) do
    previous_response_id = previous_response_id_for(history, request)

    %{
      history: history,
      previous_response_id: previous_response_id,
      expected_previous_response_id: previous_response_id,
      compaction: nil,
      run_metadata: %{}
    }
  end

  defp brain_pre_compaction_nudge(history, request, total_tokens, threshold) do
    previous_response_id = previous_response_id_for(history, request)

    %{
      history: history,
      previous_response_id: previous_response_id,
      expected_previous_response_id: previous_response_id,
      compaction: nil,
      run_metadata: %{
        "brain_pre_compaction_nudge" => %{
          "status" => "due",
          "marker" => @brain_pre_compaction_nudge_marker,
          "history_usage_tokens_before" => total_tokens,
          "token_threshold" => threshold.tokens,
          "context_length" => threshold.context_length,
          "threshold" => threshold.threshold,
          "max_threshold_tokens" => threshold.max_threshold_tokens
        }
      }
    }
  end

  defp brain_pre_compaction_nudge_due?(history, total_tokens, threshold) do
    total_tokens < threshold.effective_context_length and
      not brain_pre_compaction_nudge_seen?(history)
  end

  defp brain_pre_compaction_nudge_seen?(history) do
    Enum.any?(history, fn %Message{} = message ->
      message
      |> message_content_text()
      |> String.contains?(@brain_pre_compaction_nudge_marker)
    end)
  end

  defp brain_pre_compaction_nudge_input do
    %{
      "role" => "system",
      "content" => [
        %{
          "type" => "input_text",
          "text" =>
            "[#{@brain_pre_compaction_nudge_marker}] Automatic compaction may run soon. Before continuing, use memory_update to merge durable preferences, corrections, decisions, identifiers, dates, and project facts into the current Brain knowledge entries. Replace stale contradictory content instead of appending another version. Skip this when there is nothing worth retaining."
        }
      ]
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
      request: request,
      total_tokens: total_tokens,
      threshold: threshold
    } = context

    with {:ok, truncated_history} <-
           truncate_history_to_stable_tail(history, current_input),
         {:ok, retained_items} <- history_items_for_artifact(subject_uid, truncated_history) do
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
       %{
         history: truncated_history,
         previous_response_id: previous_response_id,
         expected_previous_response_id: previous_response_id,
         compaction: %{
           artifact_attrs: %{
             subject_uid: subject_uid,
             conversation_id: conversation_id,
             summary_text: @stable_tail_summary,
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
             checkpoint_metadata(request, %{
               "auto" => true,
               "strategy" => "stable_tail",
               "auto_truncation" => auto_truncation
             })
         },
         run_metadata: %{
           "truncation" => "auto",
           "auto_truncation" => auto_truncation
         }
       }}
    else
      {:error, :no_safe_truncation_boundary} ->
        {:error, context_overflow(total_tokens, :no_safe_truncation_boundary, "auto", threshold)}
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

  defp dropped_opaque_messages(history, truncated_history) do
    kept_ids =
      truncated_history
      |> Enum.map(& &1.id)
      |> MapSet.new()

    history
    |> Enum.reject(&MapSet.member?(kept_ids, &1.id))
    |> Enum.flat_map(&opaque_message_audit/1)
  end

  defp history_items_for_artifact(subject_uid, history) do
    history
    |> Enum.reduce_while({:ok, []}, fn
      %Message{type: "checkpoint"} = message, {:ok, chunks} ->
        case CompactionArtifacts.output_for_checkpoint(subject_uid, message) do
          {:ok, items} -> {:cont, {:ok, [retained_checkpoint_items(message, items) | chunks]}}
          {:error, _reason} = error -> {:halt, error}
        end

      %Message{content: content}, {:ok, chunks} when is_list(content) ->
        {:cont, {:ok, [content | chunks]}}

      %Message{}, {:ok, chunks} ->
        {:cont, {:ok, chunks}}
    end)
    |> case do
      {:ok, chunks} -> {:ok, chunks |> Enum.reverse() |> List.flatten()}
      {:error, _reason} = error -> error
    end
  end

  defp retained_checkpoint_items(
         %Message{metadata: %{"strategy" => "stable_tail"}},
         [%{"type" => "compaction", "created_by" => "ankole-aigateway"} | items]
       ),
       do: items

  defp retained_checkpoint_items(_message, items), do: items

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

  defp truncate_history_to_stable_tail(history, current_input) do
    {checkpoint, tail} = split_last_compaction(history)
    tail_count = length(tail)
    minimum_count = min(tail_rows(), tail_count)
    boundary_plan = compaction_boundary_plan(tail, current_input)

    case Enum.find(Range.new(minimum_count, tail_count), fn retained_count ->
           prefix_count = tail_count - retained_count
           safe_row_boundary?(boundary_plan, prefix_count)
         end) do
      nil -> {:error, :no_safe_truncation_boundary}
      retained_count -> {:ok, checkpoint ++ Enum.take(tail, -retained_count)}
    end
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

  defp compaction_candidate(
         subject_uid,
         history,
         current_input,
         retained_tail_budget_tokens \\ nil
       ) do
    with %Message{} = anchor <- List.last(history),
         rows_after_compaction = rows_after_last_compaction(history),
         preferred_prefix_count when preferred_prefix_count > 0 <-
           length(rows_after_compaction) - tail_rows(),
         compactable_count =
           rows_after_compaction
           |> Enum.take_while(&text_compactable_message?/1)
           |> length(),
         prefix_count when is_integer(prefix_count) and prefix_count > 0 <-
           compaction_prefix_count(
             rows_after_compaction,
             current_input,
             preferred_prefix_count,
             compactable_count,
             retained_tail_budget_tokens
           ),
         prefix = Enum.take(rows_after_compaction, prefix_count),
         %Message{} = _covers_until <- List.last(prefix) do
      retained_tail = Enum.drop(rows_after_compaction, length(prefix))
      prefix_items = messages_to_items(prefix)

      {retained_user_originals, _used_tokens} =
        CompactionRetention.collect_user_originals(
          prefix_items,
          user_message_budget_tokens()
        )

      {:ok,
       %{
         anchor: anchor,
         prefix: prefix,
         retained_tail: retained_tail,
         retained_user_originals: retained_user_originals,
         retained_pending_clarify: CompactionRetention.collect_pending_clarify(prefix_items),
         recent_items: messages_to_items(retained_tail) ++ input_items(current_input),
         previous_chat_history: previous_compaction_summary(subject_uid, history),
         tail_rows_requested: tail_rows()
       }}
    else
      _value -> {:error, :no_compaction_candidate}
    end
  end

  defp compaction_prefix_count(
         _rows_after_compaction,
         _current_input,
         _preferred_prefix_count,
         0,
         _retained_tail_budget_tokens
       ),
       do: nil

  defp compaction_prefix_count(
         rows_after_compaction,
         current_input,
         preferred_prefix_count,
         compactable_count,
         retained_tail_budget_tokens
       ) do
    start_count = min(preferred_prefix_count, compactable_count)
    boundary_plan = compaction_boundary_plan(rows_after_compaction, current_input)

    forward_counts = Enum.to_list(start_count..compactable_count)

    backward_counts =
      if start_count > 1,
        do: 1..(start_count - 1) |> Enum.to_list() |> Enum.reverse(),
        else: []

    Enum.find(forward_counts ++ backward_counts, fn count ->
      safe_row_boundary?(boundary_plan, count) and
        retained_tail_within_budget?(boundary_plan, count, retained_tail_budget_tokens)
    end)
  end

  defp compaction_boundary_plan(rows, current_input) do
    row_items = Enum.map(rows, &message_items/1)
    current_items = input_items(current_input)
    row_stats = Enum.map(row_items, &json_item_stats/1)
    current_stats = json_item_stats(current_items)

    prefix_item_counts =
      [
        0
        | Enum.scan(row_stats, 0, fn %{count: count}, total -> total + count end)
      ]
      |> List.to_tuple()

    total_row_stats =
      Enum.reduce(row_stats, %{count: 0, bytes: 0}, fn stats, total ->
        %{count: total.count + stats.count, bytes: total.bytes + stats.bytes}
      end)

    prefix_stats =
      [
        %{count: 0, bytes: 0}
        | Enum.scan(row_stats, %{count: 0, bytes: 0}, fn stats, prefix ->
            %{count: prefix.count + stats.count, bytes: prefix.bytes + stats.bytes}
          end)
      ]

    tail_token_estimates =
      prefix_stats
      |> Enum.map(fn prefix ->
        tail_count = total_row_stats.count - prefix.count + current_stats.count
        tail_bytes = total_row_stats.bytes - prefix.bytes + current_stats.bytes
        json_list_token_estimate(tail_count, tail_bytes)
      end)
      |> List.to_tuple()

    all_items = List.flatten(row_items) ++ current_items

    %{
      safe_item_cuts: ResponseItems.safe_boundary_cuts(all_items),
      prefix_item_counts: prefix_item_counts,
      tail_token_estimates: tail_token_estimates
    }
  end

  defp json_item_stats(items) do
    Enum.reduce(items, %{count: 0, bytes: 0}, fn item, stats ->
      %{count: stats.count + 1, bytes: stats.bytes + byte_size(Ankole.JSON.encode!(item))}
    end)
  end

  defp json_list_token_estimate(item_count, item_bytes) do
    comma_bytes = max(item_count - 1, 0)
    encoded_bytes = 2 + item_bytes + comma_bytes
    max(div(encoded_bytes, 4), 1)
  end

  defp safe_row_boundary?(plan, row_count) do
    MapSet.member?(plan.safe_item_cuts, elem(plan.prefix_item_counts, row_count))
  end

  defp retained_tail_within_budget?(_plan, _row_count, nil), do: true

  defp retained_tail_within_budget?(
         plan,
         row_count,
         retained_tail_budget_tokens
       ) do
    elem(plan.tail_token_estimates, row_count) <= retained_tail_budget_tokens
  end

  defp rows_after_last_compaction(history) do
    {_checkpoint, rest} = split_last_compaction(history)
    rest
  end

  # The checkpoint side is a list so that a caller can prepend it without a
  # separate empty-history branch.
  defp split_last_compaction(history) do
    case history
         |> Enum.with_index()
         |> Enum.filter(fn {row, _index} -> row.type == "checkpoint" end) do
      [] ->
        {[], history}

      indexed ->
        {row, index} = List.last(indexed)
        {[row], Enum.drop(history, index + 1)}
    end
  end

  defp previous_compaction_summary(subject_uid, history) do
    history
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{type: "checkpoint"} = checkpoint ->
        case CompactionArtifacts.summary_for_checkpoint(subject_uid, checkpoint) do
          {:ok, summary} when is_binary(summary) -> summary
          _missing_or_invalid -> nil
        end

      _row ->
        nil
    end)
  end

  defp summarize_candidate(subject_uid, candidate, request) do
    request_model = Map.get(request, "model")
    items = messages_to_items(candidate.prefix)
    recent_items = Map.get(candidate, :recent_items, [])

    summarizer_selectors(request_model, request)
    |> Enum.reduce_while({:error, :summarizer_model_unavailable}, fn selector, _last_error ->
      with {:ok, runtime} <- resolve_summarizer_runtime(subject_uid, selector),
           {:ok, summary} <-
             summarize_rendered(
               subject_uid,
               runtime,
               selector,
               items,
               candidate.previous_chat_history,
               recent_items: recent_items
             ) do
        {:halt, {:ok, summary}}
      else
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  defp summarize_standalone(subject_uid, candidate, request) do
    request
    |> Map.fetch!("model")
    |> summarizer_selectors(request)
    |> Enum.reduce_while({:error, :summarizer_model_unavailable}, fn selector, _last_error ->
      with {:ok, runtime} <- resolve_summarizer_runtime(subject_uid, selector),
           {:ok, summary} <-
             summarize_rendered(
               subject_uid,
               runtime,
               selector,
               candidate.prefix_items,
               candidate.previous_chat_history,
               recent_items: []
             ) do
        {:halt, {:ok, summary}}
      else
        {:error, _reason} = error -> {:cont, error}
      end
    end)
  end

  defp summarize_rendered(subject_uid, runtime, selector, items, previous_chat_history, opts) do
    recent_context_verbatim = render_recent_context(Keyword.get(opts, :recent_items, []))
    budget = render_budget(runtime, previous_chat_history, recent_context_verbatim)
    caps = CompactionRender.default_caps()

    prompt =
      build_summarizer_prompt(items, previous_chat_history, recent_context_verbatim, budget, caps)

    case call_summarizer(subject_uid, runtime, selector, prompt) do
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

          call_summarizer(subject_uid, runtime, selector, tight_prompt)
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

  defp resolve_summarizer_runtime(subject_uid, selector) do
    ResponsesPreparation.resolve_runtime(subject_uid, %{"model" => selector})
  end

  defp call_summarizer(subject_uid, runtime, selector, prompt) do
    case request_summary(
           subject_uid,
           runtime,
           selector,
           prompt,
           summarizer_output_cap(runtime)
         ) do
      {:ok, %{truncated: true} = truncated_summary} ->
        case request_summary(
               subject_uid,
               runtime,
               selector,
               prompt,
               summarizer_retry_output_cap(runtime)
             ) do
          {:ok, retried_summary} -> {:ok, retried_summary}
          {:error, _retry_failed} -> {:ok, truncated_summary}
        end

      other ->
        other
    end
  end

  # Scale the output reservation with the summarizer's window so a small-context
  # summarizer keeps enough input render budget for the tighter context-error retry.
  defp summarizer_output_cap(runtime) do
    min(@summarizer_max_output_tokens, floor(summarizer_context_length(runtime) * 0.2))
  end

  defp summarizer_retry_output_cap(runtime) do
    min(@summarizer_retry_max_output_tokens, floor(summarizer_context_length(runtime) * 0.4))
  end

  defp request_summary(subject_uid, runtime, selector, prompt, max_output_tokens) do
    cache_key = get_in(runtime, ["request_context", "cache_key"])

    request =
      %{
        "model" => selector,
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
         {:ok, text} <- extract_summary_text(body) do
      {:ok,
       %{
         text: text,
         model: Map.get(runtime, "model", selector),
         selector: selector,
         usage: Map.get(body, "usage", %{}),
         truncated: summary_truncated?(body)
       }}
    end
  end

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

  defp summarizer_selectors(request_model, request) do
    selectors =
      if get_in(request, ["reasoning", "effort"]) in ["high", "xhigh"] do
        ["primary", request_model]
      else
        ["light", "primary", request_model]
      end

    selectors
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp standalone_model(%{"model" => model}) when is_binary(model) do
    case String.trim(model) do
      "" -> {:error, :missing_model}
      _model -> {:ok, model}
    end
  end

  defp standalone_model(_request), do: {:error, :missing_model}

  defp validate_compact_previous_response_id(nil), do: :ok
  defp validate_compact_previous_response_id(""), do: :ok

  defp validate_compact_previous_response_id("resp_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_anchor}
    end
  end

  defp validate_compact_previous_response_id(_value), do: {:error, :invalid_anchor}

  defp validate_compact_conversation_id(nil), do: :ok
  defp validate_compact_conversation_id(""), do: :ok

  defp validate_compact_conversation_id("conv_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_conversation}
    end
  end

  defp validate_compact_conversation_id(_value), do: {:error, :invalid_conversation}

  defp decode_compact_conversation_id("conv_" <> uuid), do: uuid

  defp nonempty_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonempty_binary?(_value), do: false

  defp standalone_input(%{"input" => []}), do: {:error, :missing_input}
  defp standalone_input(%{"input" => input}) when is_list(input), do: {:ok, input}

  defp standalone_input(%{"input" => input}) when is_binary(input) do
    {:ok, [%{"type" => "message", "role" => "user", "content" => input}]}
  end

  defp standalone_input(_request), do: {:error, :missing_input}

  # An off switch resolves no runtime. `compact_standalone` passes this empty
  # map only to `UpstreamCompaction.compact/4`, which requires a map argument
  # and returns `{:fallback, :upstream_compaction_disabled}` before it reads
  # the runtime.
  defp compact_response_runtime(_subject_uid, _request, false), do: {:ok, %{}}

  defp compact_response_runtime(subject_uid, request, true),
    do: ResponsesPreparation.resolve_runtime(subject_uid, request)

  defp standalone_compaction_candidate(subject_uid, original_input, resolved_input) do
    {region_start_index, previous_compaction_item} = items_after_last_compaction(original_input)
    prefix_items = Enum.drop(resolved_input, region_start_index)
    original_region = Enum.drop(original_input, region_start_index)

    if prefix_items == [] do
      {:error, :no_compaction_candidate}
    else
      {previous_chat_history, previous_summary_discarded} =
        previous_compaction_content(subject_uid, previous_compaction_item)

      {retained_user_originals, _used_tokens} =
        CompactionRetention.collect_user_originals(original_region, user_message_budget_tokens())

      {:ok,
       %{
         prefix_items: prefix_items,
         retained_tail: [],
         retained_user_originals: retained_user_originals,
         retained_pending_clarify: CompactionRetention.collect_pending_clarify(original_region),
         previous_chat_history: previous_chat_history,
         previous_summary_discarded: previous_summary_discarded,
         tail_rows_requested: 0
       }}
    end
  end

  defp items_after_last_compaction(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce({0, nil}, fn
      {%{"type" => "compaction"} = item, index}, _last -> {index + 1, item}
      _other, last -> last
    end)
  end

  defp previous_compaction_content(_subject_uid, nil), do: {nil, false}

  defp previous_compaction_content(subject_uid, %{} = item) do
    content =
      item
      |> then(&(Map.get(&1, "encrypted_content") || Map.get(&1, "summary")))
      |> resolve_previous_compaction_handle(subject_uid)

    if usable_previous_summary?(content) do
      {content, false}
    else
      {nil, true}
    end
  end

  defp resolve_previous_compaction_handle(content, subject_uid) when is_binary(content) do
    case CompactionArtifacts.get_for_subject(subject_uid, content) do
      {:ok, artifact} -> CompactionArtifacts.summary_text(artifact) || content
      {:error, :invalid_compaction_handle} -> content
    end
  end

  defp resolve_previous_compaction_handle(content, _subject_uid), do: content

  defp usable_previous_summary?(content) when is_binary(content) do
    String.valid?(content) and byte_size(content) <= 32_768 and content =~ ~r/\s/
  end

  defp usable_previous_summary?(_content), do: false

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

  defp compaction_metadata(summary, candidate, total_tokens, flags) do
    %{
      "summarizer" => %{
        "model" => summary.model,
        "selector" => summary.selector,
        "usage" => summary.usage,
        "truncated" => summary.truncated
      },
      "history_usage_tokens_before" => total_tokens,
      "covered_message_count" => length(candidate.prefix)
    }
    |> Map.merge(flags)
  end

  defp history_usage_tokens(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(0, fn
      %Message{} = message ->
        case message_usage_tokens(message) do
          tokens when tokens > 0 -> tokens
          _missing -> nil
        end

      _message ->
        nil
    end)
  end

  defp message_usage_tokens(%Message{metadata: %{} = metadata}) do
    metadata
    |> Map.get("usage")
    |> usage_tokens()
  end

  defp message_usage_tokens(_message), do: 0

  defp usage_tokens(%{} = usage) do
    total_tokens = usage_integer(usage, ["total_tokens", "totalTokens"])

    if total_tokens > 0 do
      total_tokens
    else
      usage_integer(usage, ["input_tokens", "prompt_tokens", "inputTokens"]) +
        usage_integer(usage, ["output_tokens", "completion_tokens", "outputTokens"])
    end
  end

  defp usage_tokens(_usage), do: 0

  defp usage_integer(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _value -> false
      end
    end)
  end

  defp request_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp request_metadata(_request), do: %{}

  defp checkpoint_metadata(request, internal_metadata) do
    Map.put(internal_metadata, "request_metadata", request_metadata(request))
  end

  defp checkpoint_within_budget(candidate, summary, current_input, threshold) do
    checkpoint_items =
      candidate.retained_user_originals ++
        [
          %{
            "type" => "compaction",
            "encrypted_content" => summary.text,
            "created_by" => "ankole-aigateway"
          }
        ] ++ messages_to_items(candidate.retained_tail) ++ input_items(current_input)

    if items_token_estimate(checkpoint_items) <= checkpoint_budget_tokens(threshold) do
      :ok
    else
      {:error, :compaction_output_over_budget}
    end
  end

  defp checkpoint_budget_tokens(threshold) do
    max(threshold.tokens, CompactionRender.min_render_budget_tokens())
  end

  defp retained_tail_budget_tokens(threshold) do
    max(
      checkpoint_budget_tokens(threshold) -
        user_message_budget_tokens() -
        @summarizer_retry_max_output_tokens -
        @checkpoint_overhead_tokens,
      CompactionRender.min_render_budget_tokens()
    )
  end

  defp items_token_estimate(items) do
    items
    |> Ankole.JSON.encode!()
    |> CompactionRender.approx_tokens()
  end

  defp message_content_text(%Message{content: content}) when is_list(content) do
    content
    |> Enum.map(&CompactionRender.item_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp text_compactable_message?(%Message{type: "message", status: "complete", content: content})
       when is_list(content),
       do: Enum.all?(content, &text_compactable_item?/1)

  defp text_compactable_message?(_message), do: false

  defp text_compactable_item?(%{"type" => "message", "content" => content}),
    do: text_compactable_content?(content)

  defp text_compactable_item?(%{"role" => role, "content" => content}) when is_binary(role),
    do: text_compactable_content?(content)

  defp text_compactable_item?(%{"type" => type, "text" => text})
       when type in ["input_text", "output_text", "text"] and is_binary(text),
       do: true

  defp text_compactable_item?(%{"type" => "reasoning"}), do: true

  defp text_compactable_item?(item),
    do: ResponseItems.call_item?(item) or ResponseItems.output_item?(item)

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
    Enum.flat_map(messages, &message_items/1)
  end

  defp message_items(%Message{content: content}) when is_list(content), do: content
  defp message_items(_message), do: []

  defp input_items(items) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp input_items(_items), do: []

  defp tail_rows do
    config()
    |> Map.get("tail_rows", @default_tail_rows)
  end

  defp user_message_budget_tokens do
    config()
    |> Map.get("user_message_budget_tokens", 20_000)
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
           {:ok, tail_rows} <- optional_tail_rows(value),
           {:ok, user_message_budget_tokens} <- optional_user_message_budget_tokens(value),
           {:ok, prefer_upstream} <- optional_prefer_upstream(value) do
        {:ok,
         %{
           "threshold" => threshold,
           "max_threshold_tokens" => max_threshold_tokens,
           "tail_rows" => tail_rows,
           "user_message_budget_tokens" => user_message_budget_tokens,
           "prefer_upstream" => prefer_upstream
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
    allowed =
      MapSet.new([
        "threshold",
        "max_threshold_tokens",
        "tail_rows",
        "user_message_budget_tokens",
        "prefer_upstream"
      ])

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

  defp optional_user_message_budget_tokens(value) do
    case Map.get(value, "user_message_budget_tokens", 20_000) do
      tokens when is_integer(tokens) and tokens > 0 -> {:ok, tokens}
      _value -> {:error, :invalid_compaction_user_message_budget_tokens}
    end
  end

  defp optional_prefer_upstream(value) do
    case Map.get(value, "prefer_upstream", false) do
      prefer_upstream when is_boolean(prefer_upstream) -> {:ok, prefer_upstream}
      _value -> {:error, :invalid_compaction_prefer_upstream}
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

  defp summarizer_context_length(runtime) when is_map(runtime) do
    first_positive_integer([
      Map.get(runtime, "context_length"),
      get_in(runtime, ["model_metadata", "context_length"]),
      get_in(runtime, ["model_metadata", "top_provider", "context_length"]),
      provider_model_context_length(runtime)
    ]) || CompactionRender.fallback_summarizer_context_tokens()
  end

  defp summarizer_context_length(_runtime),
    do: CompactionRender.fallback_summarizer_context_tokens()

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

  defp context_length_error?(reason) do
    reason
    |> inspect()
    |> String.match?(~r/context|too long|too large|maximum.*(length|tokens)/i)
  end
end
