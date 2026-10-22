defmodule Ankole.AIGateway.CompactionRequests do
  alias Ankole.AIGateway.ResponseChain
  @moduledoc "Manual and client-triggered compaction protocols."
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CompactionCandidate
  alias Ankole.AIGateway.CompactionHistory
  alias Ankole.AIGateway.CompactionPolicy
  alias Ankole.AIGateway.CompactionSummarizer
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.UpstreamCompaction

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.{Attrs, Logging}

  defmodule ManualContext do
    @moduledoc false
    @enforce_keys [
      :subject_uid,
      :conversation_id,
      :history,
      :brain_context_pack,
      :request,
      :total_tokens,
      :runtime,
      :native_state,
      :visible_previous_response_id,
      :upstream_compaction?,
      :identity
    ]
    defstruct @enforce_keys
  end

  @doc """
  Returns whether one Responses request carries the client's compaction trigger.
  """
  @spec compaction_trigger?(map()) :: boolean()
  def compaction_trigger?(%{"input" => input}) when is_list(input),
    do: Enum.any?(input, &compaction_trigger_item?/1)

  def compaction_trigger?(_request), do: false

  @doc """
  Serves one `compaction_trigger` request and returns its Response body.

  AIGateway owns this protocol for every consumer, so the trigger never
  reaches a Provider adapter by itself. A stateful caller compacts the stored
  conversation, because AIGateway holds that history and the caller sends only
  the current turn. A stateless caller compacts the input it sent, because only
  that caller holds its history. Both return one `compaction` output item, and
  a stateful response carries the checkpoint id so the caller's next turn
  continues from it.
  """
  @spec compact_from_trigger(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def compact_from_trigger(subject_uid, request, identity \\ [])

  def compact_from_trigger(subject_uid, request, identity) when is_map(request) do
    request = Attrs.normalize_external_attrs(request)

    # What the caller sent decides which history is compacted. A caller that
    # sends only the trigger keeps its history here; a caller that sends history
    # with the trigger holds its own, and AIGateway must not compact a stored
    # conversation instead of what it was given.
    if trigger_only_input?(request) do
      case trigger_conversation_id(subject_uid, request) do
        {:ok, nil} ->
          stateless_trigger_response(subject_uid, drop_compaction_trigger(request), identity)

        {:ok, conversation_id} ->
          stateful_trigger_response(subject_uid, conversation_id, request, identity)

        {:error, _reason} = error ->
          error
      end
    else
      stateless_trigger_response(subject_uid, drop_compaction_trigger(request), identity)
    end
  end

  def compact_from_trigger(_subject_uid, _request, _identity), do: {:error, :invalid_request_body}

  @doc """
  Renders one compaction reply as the public event sequence.

  Every streaming transport shows the same frames, so the caller cannot tell
  which one it used.
  """
  @spec trigger_events(map()) :: [map()]
  def trigger_events(%{} = response) do
    created = response |> Map.put("status", "in_progress") |> Map.put("output", [])

    item_events =
      response
      |> Map.get("output", [])
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        [
          %{"type" => "response.output_item.added", "output_index" => index, "item" => item},
          %{"type" => "response.output_item.done", "output_index" => index, "item" => item}
        ]
      end)

    ([%{"type" => "response.created", "response" => created}] ++
       item_events ++ [%{"type" => "response.completed", "response" => response}])
    |> Enum.with_index()
    |> Enum.map(fn {event, sequence} -> Map.put(event, "sequence_number", sequence) end)
  end

  defp compaction_trigger_item?(%{"type" => "compaction_trigger"}), do: true
  defp compaction_trigger_item?(_item), do: false

  defp drop_compaction_trigger(%{"input" => input} = request) when is_list(input),
    do: Map.put(request, "input", Enum.reject(input, &compaction_trigger_item?/1))

  defp drop_compaction_trigger(request), do: request

  defp trigger_only_input?(%{"input" => input}) when is_list(input),
    do: Enum.all?(input, &compaction_trigger_item?/1)

  defp trigger_only_input?(_request), do: false

  # A stateful caller names its history with either anchor. Both resolve to the
  # conversation AIGateway stores, because that history is what it compacts.
  defp trigger_conversation_id(subject_uid, %{"conversation" => value} = request)
       when is_binary(value) and value != "" do
    with :ok <- validate_compact_conversation_id(value),
         {:ok, conversation} <-
           ResponseChain.get_conversation_for_subject(
             subject_uid,
             decode_compact_conversation_id(value)
           ) do
      {:ok, conversation.id}
    else
      {:error, _reason} ->
        trigger_conversation_id(subject_uid, Map.delete(request, "conversation"))
    end
  end

  defp trigger_conversation_id(
         subject_uid,
         %{"previous_response_id" => value, "store" => true}
       )
       when is_binary(value) and value != "" do
    case ResponseChain.get_response_for_subject(subject_uid, value) do
      {:ok, %Message{conversation_id: conversation_id}} -> {:ok, conversation_id}
      _not_found_or_invalid -> {:error, :invalid_anchor}
    end
  end

  defp trigger_conversation_id(_subject_uid, _request), do: {:ok, nil}

  defp compaction_output_item?(%{"type" => "compaction"}), do: true
  defp compaction_output_item?(_item), do: false

  defp stateless_trigger_response(subject_uid, request, identity) do
    with {:ok, body} <- compact_response(subject_uid, request, identity) do
      # A stored compaction answers with its checkpoint id, so the caller's next
      # turn continues from it without a second lookup.
      id = get_in(body, ["ankole", "response_id"]) || Map.get(body, "id")
      {:ok, trigger_response(id, body)}
    end
  end

  defp stateful_trigger_response(subject_uid, conversation_id, request, identity) do
    with {:ok, %{compaction: checkpoint}} <-
           compact_conversation(subject_uid, conversation_id, request, identity),
         {:ok, content} <- CompactionArtifacts.content_for_checkpoint(subject_uid, checkpoint) do
      {:ok, trigger_response(CompactionArtifacts.response_id(checkpoint.id), content)}
    end
  end

  # The trigger's reply is a normal completed Response: its consumers read one
  # `compaction` output item and one terminal, not a compaction-specific body.
  #
  # Both sources carry the artifact's normalized usage, so the reply reports what
  # the compaction cost. An empty usage object is not a valid Response usage, so
  # a source without one omits the field instead of sending a shape a caller
  # cannot read.
  defp trigger_response(id, source) do
    response = %{
      "id" => id,
      "object" => "response",
      "status" => "completed",
      "output" => source |> Map.get("output", []) |> Enum.filter(&compaction_output_item?/1)
    }

    case Map.get(source, "usage") do
      usage when is_map(usage) and map_size(usage) > 0 -> Map.put(response, "usage", usage)
      _absent -> response
    end
  end

  @doc """
  Compacts the stored chain at the request's `previous_response_id`, or the
  conversation's current visible leaf when the request has no anchor.

  This is the control-plane `/compress` path. It reuses the same candidate and
  summarizer logic as automatic compaction, but it does not depend on the
  recorded history usage crossing the automatic threshold.
  """
  @spec compact_conversation(String.t(), binary(), map(), keyword()) ::
          {:ok,
           %{compaction: Message.t(), previous_response_id: binary(), history: [Message.t()]}}
          | {:error, term()}
  def compact_conversation(subject_uid, conversation_id, request \\ %{}, identity \\ [])
      when is_map(request) do
    previous_response_id = Map.get(request, "previous_response_id")

    with {:ok, conversation} <-
           ResponseChain.get_conversation_for_subject(subject_uid, conversation_id),
         :ok <- ResponseChain.validate_response_anchor(conversation.id, previous_response_id),
         history =
           ResponseChain.expand_history(conversation.id,
             previous_response_id: previous_response_id
           ),
         {:ok, runtime} <-
           ResponsesPreparation.resolve_runtime(subject_uid, %{"model" => "primary"}, identity),
         {:ok, native_state} <-
           CompactionHistory.native_checkpoint_state(subject_uid, history, runtime) do
      total_tokens = CompactionHistory.history_usage_tokens(history)
      visible_previous_response_id = CompactionHistory.previous_response_id_for(history, request)
      upstream_compaction? = CompactionPolicy.upstream_compaction?()

      compact_conversation_history(%ManualContext{
        identity: identity,
        subject_uid: subject_uid,
        conversation_id: conversation.id,
        history: history,
        brain_context_pack:
          CompactionArtifacts.checkpoint_pack(
            subject_uid,
            conversation.id,
            request,
            [],
            history,
            identity
          ),
        request: request,
        total_tokens: total_tokens,
        runtime: runtime,
        native_state: native_state,
        visible_previous_response_id: visible_previous_response_id,
        upstream_compaction?: upstream_compaction?
      })
    end
  end

  @doc """
  Creates one OpenResponses compaction resource.

  The artifact is always persisted. `store=true` additionally creates a
  checkpoint response row so clients may continue with `previous_response_id`.
  """
  @spec compact_response(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def compact_response(subject_uid, request, identity \\ [])

  def compact_response(subject_uid, request, identity) when is_map(request) do
    request = Attrs.normalize_external_attrs(request)
    upstream_compaction? = CompactionPolicy.upstream_compaction?()

    with {:ok, _model} <- standalone_model(request),
         {:ok, input} <- standalone_input(request),
         {:ok, resolved_input} <- CompactionArtifacts.resolve_input_handles(subject_uid, input),
         {:ok, store_context} <- compact_store_context(subject_uid, request) do
      store_context =
        Map.put(
          store_context,
          :brain_context_pack,
          CompactionArtifacts.checkpoint_pack(
            subject_uid,
            store_context.conversation_id,
            request,
            input,
            [],
            identity
          )
        )

      compact_standalone(
        subject_uid,
        request,
        input,
        resolved_input,
        store_context,
        upstream_compaction?,
        identity
      )
    end
  end

  def compact_response(_subject_uid, _request, _identity), do: {:error, :invalid_request_body}

  defp compact_conversation_history(%ManualContext{} = context) do
    %ManualContext{
      identity: identity,
      subject_uid: subject_uid,
      history: history,
      request: request,
      runtime: runtime,
      native_state: native_state,
      upstream_compaction?: upstream_compaction?
    } = context

    if CompactionHistory.force_local_checkpoint?(native_state, upstream_compaction?) do
      compact_conversation_locally(context)
    else
      with {:ok, input} <- CompactionHistory.history_items_for_artifact(subject_uid, history),
           {:ok, input} <- CompactionArtifacts.resolve_input_handles(subject_uid, input) do
        case UpstreamCompaction.compact(
               runtime,
               input,
               request,
               [enabled?: upstream_compaction?, subject_uid: subject_uid] ++ identity
             ) do
          {:ok, upstream} ->
            create_manual_upstream_checkpoint(context, upstream)

          {:fallback, _reason} ->
            compact_conversation_locally(context)
        end
      end
    end
  end

  defp compact_conversation_locally(%ManualContext{} = context) do
    %ManualContext{
      identity: identity,
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      history: history,
      brain_context_pack: pack,
      request: request,
      total_tokens: total_tokens,
      runtime: runtime,
      native_state: native_state,
      visible_previous_response_id: visible_previous_response_id
    } = context

    history =
      CompactionHistory.local_checkpoint_history(conversation_id, history, request, native_state)

    threshold = CompactionPolicy.threshold_spec(runtime, request)

    with {:ok, candidate} <-
           CompactionCandidate.for_history(
             subject_uid,
             history,
             [],
             CompactionPolicy.retained_tail_budget_tokens(threshold, pack)
           ),
         candidate = %{candidate | brain_context_pack: pack},
         {:ok, summary} <-
           CompactionSummarizer.summarize_candidate(subject_uid, candidate, identity),
         :ok <- CompactionArtifacts.checkpoint_within_budget(candidate, summary, [], threshold),
         {:ok, artifact} <-
           CompactionArtifacts.create_artifact_for_candidate(
             subject_uid,
             conversation_id,
             candidate,
             summary
           ),
         {:ok, checkpoint} <-
           ResponseChain.create_compaction_checkpoint(%{
             subject_uid: subject_uid,
             previous_response_id: visible_previous_response_id,
             artifact: artifact,
             metadata:
               CompactionArtifacts.checkpoint_metadata(
                 request,
                 CompactionArtifacts.compaction_metadata(summary, candidate, total_tokens, %{
                   "auto" => false,
                   "manual" => true
                 }),
                 runtime["provider_id"]
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
      brain_context_pack: pack,
      runtime: runtime,
      visible_previous_response_id: previous_response_id
    } = context

    with {:ok, attrs} <-
           CompactionArtifacts.with_upstream_pack(
             CompactionArtifacts.upstream_artifact_attrs(subject_uid, conversation_id, upstream),
             pack,
             [],
             CompactionPolicy.threshold_spec(runtime, request)
           ),
         {:ok, artifact} <- CompactionArtifacts.insert_artifact(attrs),
         {:ok, checkpoint} <-
           ResponseChain.create_compaction_checkpoint(%{
             subject_uid: subject_uid,
             previous_response_id: previous_response_id,
             artifact: artifact,
             metadata:
               CompactionArtifacts.checkpoint_metadata(
                 request,
                 %{"auto" => false, "manual" => true, "source" => "upstream"},
                 runtime["provider_id"]
               )
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
         ResponseChain.expand_history(conversation_id,
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
         false,
         identity
       ) do
    compact_standalone_locally(
      subject_uid,
      request,
      original_input,
      resolved_input,
      store_context,
      nil,
      identity
    )
  end

  defp compact_standalone(
         subject_uid,
         request,
         original_input,
         resolved_input,
         store_context,
         true,
         identity
       ) do
    with {:ok, runtime} <- ResponsesPreparation.resolve_runtime(subject_uid, request, identity) do
      case UpstreamCompaction.compact(
             runtime,
             resolved_input,
             request,
             [enabled?: true, subject_uid: subject_uid] ++ identity
           ) do
        {:ok, upstream} ->
          with {:ok, attrs} <-
                 CompactionArtifacts.with_upstream_pack(
                   CompactionArtifacts.upstream_artifact_attrs(
                     subject_uid,
                     store_context.conversation_id,
                     upstream
                   ),
                   store_context.brain_context_pack,
                   [],
                   CompactionPolicy.threshold_spec(runtime, request)
                 ),
               {:ok, artifact} <- CompactionArtifacts.insert_artifact(attrs),
               {:ok, ankole_extension} <-
                 maybe_store_compaction_checkpoint(
                   subject_uid,
                   request,
                   store_context,
                   artifact,
                   Map.get(runtime, "provider_id")
                 ) do
            {:ok, CompactionArtifacts.response_body(artifact, ankole: ankole_extension)}
          end

        {:fallback, _reason} ->
          compact_standalone_locally(
            subject_uid,
            request,
            original_input,
            resolved_input,
            store_context,
            runtime,
            identity
          )
      end
    end
  end

  defp compact_standalone_locally(
         subject_uid,
         request,
         original_input,
         resolved_input,
         store_context,
         runtime,
         identity
       ) do
    with {:ok, candidate} <-
           CompactionCandidate.for_input(subject_uid, original_input, resolved_input),
         :ok <- warn_opaque_preserved(candidate),
         {:ok, runtime} <- standalone_local_runtime(runtime, subject_uid, request, identity),
         threshold = CompactionPolicy.threshold_spec(runtime, request),
         {:ok, summary} <- summarize_standalone(subject_uid, candidate, identity),
         candidate = %{candidate | brain_context_pack: store_context.brain_context_pack},
         :ok <- CompactionArtifacts.checkpoint_within_budget(candidate, summary, [], threshold),
         {:ok, artifact} <-
           create_standalone_artifact(subject_uid, store_context, candidate, summary),
         {:ok, ankole_extension} <-
           maybe_store_compaction_checkpoint(
             subject_uid,
             request,
             store_context,
             artifact,
             Map.get(runtime, "provider_id")
           ) do
      {:ok, CompactionArtifacts.response_body(artifact, ankole: ankole_extension)}
    end
  end

  defp standalone_local_runtime(%{} = runtime, _subject_uid, _request, _identity),
    do: {:ok, runtime}

  defp standalone_local_runtime(nil, subject_uid, request, identity),
    do: ResponsesPreparation.resolve_runtime(subject_uid, request, identity)

  # The local summary cannot read Provider ciphertext, so the checkpoint keeps
  # it verbatim instead of failing the compaction. The warning is the operator
  # fact: the summary covers only the items after the preserved Provider state.
  defp warn_opaque_preserved(%{opaque_prefix: []}), do: :ok

  defp warn_opaque_preserved(%{opaque_prefix: opaque_prefix}) do
    Logging.warning(
      "ai_gateway.compaction_opaque_prefix_preserved",
      "local compaction preserved provider-owned compaction state verbatim",
      %{opaque_prefix_items: length(opaque_prefix)}
    )

    :ok
  end

  defp create_standalone_artifact(subject_uid, store_context, candidate, summary) do
    CompactionArtifacts.insert_artifact(%{
      subject_uid: subject_uid,
      conversation_id: store_context.conversation_id,
      summary_text: summary.text,
      brain_context_pack: candidate.brain_context_pack,
      retained_items: candidate.retained_client_tool_search ++ candidate.retained_tail,
      retained_user_originals:
        candidate.retained_user_originals ++ candidate.retained_pending_clarify,
      opaque_prefix: candidate.opaque_prefix,
      retention:
        %{
          "strategy" => "standalone_user_messages",
          "requested" => candidate.tail_rows_requested,
          "actual" => length(candidate.retained_tail),
          "user_budget_tokens" => CompactionPolicy.user_message_budget_tokens(),
          "user_message_count" => length(candidate.retained_user_originals)
        }
        |> Ankole.Attrs.put_present(
          "previous_summary_discarded",
          if(candidate.previous_summary_discarded, do: true, else: nil)
        )
        |> Ankole.Attrs.put_present(
          "opaque_prefix_items",
          if(candidate.opaque_prefix != [], do: length(candidate.opaque_prefix), else: nil)
        ),
      usage: summary.usage
    })
  end

  defp maybe_store_compaction_checkpoint(
         subject_uid,
         _request,
         %{store?: true} = store_context,
         artifact,
         issuer
       ) do
    with {:ok, checkpoint} <-
           ResponseChain.create_compaction_checkpoint(%{
             subject_uid: subject_uid,
             conversation_id: store_context.conversation_id,
             previous_response_id: store_context.previous_response_id,
             artifact: artifact,
             metadata:
               CompactionArtifacts.put_issuer(
                 %{"request_metadata" => store_context.metadata},
                 issuer
               )
           }) do
      {:ok,
       %{
         "stored" => true,
         "response_id" => CompactionArtifacts.response_id(checkpoint.id),
         "conversation" => "conv_#{checkpoint.conversation_id}"
       }}
    end
  end

  defp maybe_store_compaction_checkpoint(
         _subject_uid,
         _request,
         _store_context,
         _artifact,
         _issuer
       ),
       do: {:ok, nil}

  defp compact_store_context(subject_uid, %{"store" => true} = request) do
    previous_response_id = Map.get(request, "previous_response_id")
    conversation_id = Map.get(request, "conversation")

    with :ok <- validate_compact_conversation_id(conversation_id) do
      cond do
        nonempty_binary?(previous_response_id) ->
          case ResponseChain.get_response_for_subject(subject_uid, previous_response_id) do
            {:ok, %Message{status: :complete} = anchor} ->
              {:ok,
               %{
                 store?: true,
                 conversation_id: anchor.conversation_id,
                 previous_response_id: previous_response_id,
                 metadata: CompactionArtifacts.request_metadata(request)
               }}

            {:ok, %Message{}} ->
              {:error, :invalid_anchor}

            {:error, :not_found} ->
              {:error, :invalid_anchor}
          end

        nonempty_binary?(conversation_id) ->
          raw_conversation_id = decode_compact_conversation_id(conversation_id)

          with {:ok, conversation} <-
                 ResponseChain.get_conversation_for_subject(subject_uid, raw_conversation_id) do
            {:ok,
             %{
               store?: true,
               conversation_id: conversation.id,
               previous_response_id: nil,
               metadata: CompactionArtifacts.request_metadata(request)
             }}
          end

        true ->
          with {:ok, conversation} <-
                 Conversations.create_managed_stateful_responses_conversation(subject_uid,
                   metadata: CompactionArtifacts.request_metadata(request)
                 ) do
            {:ok,
             %{
               store?: true,
               conversation_id: conversation.id,
               previous_response_id: nil,
               metadata: CompactionArtifacts.request_metadata(request)
             }}
          end
      end
    else
      {:error, _reason} = error -> error
    end
  end

  # A caller without `store=true` compacts the input it sent. It cannot also
  # name stored history: HTTP rejects both selectors before dispatch, and the
  # WebSocket resolves its connection-local anchor into `input` first.
  defp compact_store_context(_subject_uid, _request),
    do: {:ok, %{store?: false, conversation_id: nil, previous_response_id: nil, metadata: %{}}}

  defp summarize_standalone(subject_uid, candidate, identity) do
    CompactionSummarizer.summarize(
      subject_uid,
      candidate.prefix_items,
      candidate.previous_chat_history,
      identity
    )
  end

  defp standalone_model(%{"model" => model}) when is_binary(model) do
    case String.trim(model) do
      "" -> {:error, :missing_model}
      _model -> {:ok, model}
    end
  end

  defp standalone_model(_request), do: {:error, :missing_model}

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
end
