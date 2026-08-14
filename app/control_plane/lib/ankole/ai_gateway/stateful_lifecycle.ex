defmodule Ankole.AIGateway.StatefulLifecycle do
  @moduledoc """
  Owns the control-plane lifecycle for locally stored Responses.

  AIGateway stays the public facade. This module owns the stateful continuation
  rules that need durable history, compaction, response projection, and recovery
  semantics to remain in one place.
  """

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CodexVision
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.MapUtils
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.RequestContext
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.UniversalAIRequest

  @websocket_continuation_fields ~w(previous_response_id conversation)
  @stateful_provider_replay_marker "__ankole_stateful_provider_replay"
  @input_message_roles ~w(system developer user)
  @stateful_request_metadata_fields ~w(
    instructions tools tool_choice truncation parallel_tool_calls text top_p
    presence_penalty frequency_penalty top_logprobs temperature reasoning
    max_output_tokens max_tool_calls service_tier prompt_cache_key
    safety_identifier user
  )

  @tool_result_record_db_retry_delays_ms [50, 100, 200, 400, 800, 1_600]
  # Stateful history replays as Responses items. Only these wires translate
  # bare client tool calls and outputs faithfully. Other wires cannot preserve
  # those pairs in provider history. Stateless requests do not pass this gate.
  @stateful_replay_api_resolvers [:openai_responses, :openai_chat_completions]

  @doc false
  @spec retrieve_response(String.t(), binary()) :: {:ok, %{body: map()}} | {:error, term()}
  def retrieve_response(subject_uid, response_id) do
    with :ok <- validate_external_response_id(response_id),
         {:ok, %Message{} = message} <-
           StatefulResponses.get_response_for_subject(subject_uid, response_id),
         {:ok, body} <- response_resource(message) do
      {:ok, %{body: body}}
    else
      _not_found_or_invalid ->
        {:error, :not_found}
    end
  end

  @doc false
  @spec compact_response(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def compact_response(subject_uid, request) when is_map(request) do
    request = normalize_request_keys(request)

    with {:ok, body} <- Compaction.compact_response(subject_uid, request) do
      {:ok, %{body: body}}
    end
  end

  def compact_response(_subject_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec record_tool_results(String.t(), map()) :: {:ok, %{body: map()}} | {:error, term()}
  def record_tool_results(subject_uid, request) when is_map(request) do
    with {:ok, attrs} <- tool_result_record_attrs(subject_uid, request, %{}),
         {:ok, %Message{} = message} <-
           record_tool_results_with_transient_db_retry(attrs),
         {:ok, body} <- response_resource(message) do
      {:ok, %{body: body}}
    end
  end

  def record_tool_results(_subject_uid, _request), do: {:error, :invalid_request_body}

  @doc false
  @spec record_tool_results_in_tx(module(), String.t(), map(), map()) ::
          {:ok, %{message: Message.t(), body: map(), disposition: :inserted | :existing}}
          | {:error, term()}
  def record_tool_results_in_tx(repo, subject_uid, request, internal_metadata)
      when is_map(request) and is_map(internal_metadata) do
    with {:ok, attrs} <- tool_result_record_attrs(subject_uid, request, internal_metadata),
         {:ok, %Message{} = message, disposition} <-
           StatefulResponses.record_tool_results_in_tx(repo, attrs),
         {:ok, body} <- response_resource(message) do
      {:ok, %{message: message, body: body, disposition: disposition}}
    end
  end

  @doc false
  @spec prepare_websocket_provider_request(String.t(), map(), keyword()) ::
          {:ok, UniversalAIRequest.t(), map() | nil} | {:error, term()}
  def prepare_websocket_provider_request(subject_uid, request, opts \\ []) do
    normalized_request = normalize_request_keys(request)
    request_context = websocket_request_context(opts, normalized_request)

    with :ok <- validate_websocket_stateful_shape(request),
         {:ok, runtime} <-
           Resolver.resolve_request_model(
             subject_uid,
             "llm",
             Map.put(normalized_request, "__ankole_request_context", request_context)
           ),
         {:ok, normalized_request} <- CodexVision.adapt(subject_uid, normalized_request),
         {:ok, request_for_provider, run_attrs} <-
           provider_websocket_request(subject_uid, normalized_request, runtime),
         {:ok, %{spec: prepared_request}} <-
           ResponsesPreparation.prepare_with_runtime(
             subject_uid,
             runtime,
             request_for_provider,
             stream?: true,
             request_context: put_run_conversation_id(request_context, run_attrs)
           ) do
      {:ok, prepared_request, run_attrs}
    end
  end

  @doc false
  @spec prepare_and_start_websocket_provider_request(String.t(), map(), keyword()) ::
          {:ok, UniversalAIRequest.t(), map() | nil} | {:error, term()}
  def prepare_and_start_websocket_provider_request(subject_uid, request, opts \\ []) do
    request = normalize_request_keys(request)
    request_context = websocket_request_context(opts, request)
    resolver_request = Map.put(request, "__ankole_request_context", request_context)

    with :ok <- validate_websocket_stateful_shape(request),
         {:ok, runtime} <- Resolver.resolve_request_model(subject_uid, "llm", resolver_request),
         {:ok, request} <- CodexVision.adapt(subject_uid, request) do
      if request["store"] == true do
        prepare_and_start_stateful_provider_request(
          subject_uid,
          request,
          runtime,
          request_context
        )
      else
        with {:ok, request_for_provider, nil} <-
               provider_websocket_request(subject_uid, request, runtime),
             {:ok, %{spec: prepared_request}} <-
               ResponsesPreparation.prepare_with_runtime(
                 subject_uid,
                 runtime,
                 request_for_provider,
                 stream?: true,
                 request_context: request_context
               ) do
          {:ok, prepared_request, nil}
        end
      end
    end
  end

  @doc false
  def commit_socket_open_error(nil, _reason), do: :ok

  def commit_socket_open_error(%{message_id: message_id}, reason) do
    StatefulResponses.commit_error(message_id, [], socket_open_error_details(reason))

    :ok
  end

  @doc false
  @spec recover_provider_replay(map()) ::
          {:ok, UniversalAIRequest.t() | map(), map()} | {:error, term()}
  def recover_provider_replay(%{
        message_id: message_id,
        subject_uid: subject_uid,
        conversation_id: conversation_id,
        replay_recovery: %{
          request: request,
          runtime: runtime,
          request_context: request_context
        }
      }) do
    with %Message{status: "generating"} = message <- StatefulResponses.get_message(message_id),
         true <-
           message.subject_uid == subject_uid and message.conversation_id == conversation_id,
         previous_response_id when is_binary(previous_response_id) <-
           response_id(message.previous_message_id),
         {:ok, plan} <-
           Compaction.plan_replay_recovery(
             subject_uid,
             conversation_id,
             previous_response_id,
             message.content,
             request,
             runtime
           ),
         {:ok, %{checkpoint: checkpoint, message: message}} <-
           StatefulResponses.install_replay_recovery_checkpoint(message, plan),
         {:ok, conversation} <-
           StatefulResponses.get_conversation_for_subject(subject_uid, conversation_id),
         checkpoint_response_id = response_id(checkpoint.id),
         history =
           StatefulResponses.expand_history(conversation_id,
             previous_response_id: checkpoint_response_id,
             protected_tail_items: message.content
           ),
         context = %{
           subject_uid: subject_uid,
           conversation: conversation,
           request: request,
           current_input: message.content,
           recovered_call_ids: [],
           compaction: %{
             history: history,
             previous_response_id: checkpoint_response_id,
             run_metadata:
               Compaction.put_checkpoint_response_id(
                 plan.run_metadata,
                 checkpoint_response_id
               )
           }
         },
         {:ok, request_for_provider, run_attrs} <-
           provider_request_from_stateful_context(context, runtime),
         {:ok, message} <-
           StatefulResponses.merge_generating_response_metadata(message, run_attrs.metadata),
         {:ok, %{spec: prepared_request}} <-
           ResponsesPreparation.prepare_with_runtime(
             subject_uid,
             runtime,
             request_for_provider,
             stream?: true,
             request_context: request_context
           ) do
      recovery = %{request: request, runtime: runtime, request_context: request_context}
      {:ok, prepared_request, response_stream_context(message, recovery)}
    else
      false -> {:error, :stateful_replay_recovery_unavailable}
      nil -> {:error, :stateful_replay_recovery_unavailable}
      {:error, _reason} = error -> error
      _invalid -> {:error, :stateful_replay_recovery_unavailable}
    end
  end

  def recover_provider_replay(_stateful_context),
    do: {:error, :stateful_replay_recovery_unavailable}

  # Step 1: Expands the message chain for a stateful run and injects the
  # expanded history into the provider-facing request input.
  #
  # This replaces the old worker-side history resolution path: the gateway now
  # owns history expansion (plan §3.9 step 3).
  #
  # After expansion, stateful fields are stripped from the request so they
  # are not sent to the upstream provider (plan §3.9 step 6):
  #   - previous_response_id (Ankole UUID, would 404 on OpenAI)
  #   - store (Ankole stateful switch; provider dispatch disables upstream storage)
  #   - conversation (internal correlation)
  defp provider_websocket_request(subject_uid, request, runtime) do
    request = normalize_request_keys(request)

    if request["store"] == true do
      expand_and_inject_history(subject_uid, request, runtime)
    else
      with {:ok, request} <-
             CompactionArtifacts.resolve_request_input_handles(subject_uid, request) do
        {:ok, strip_stateful_provider_fields(request), nil}
      end
    end
  end

  defp expand_and_inject_history(subject_uid, request, runtime) do
    with {:ok, context} <-
           build_stateful_request_context(
             subject_uid,
             request,
             runtime,
             &Compaction.maybe_compact_history/6
           ) do
      provider_request_from_stateful_context(context, runtime)
    end
  end

  defp prepare_and_start_stateful_provider_request(
         subject_uid,
         request,
         runtime,
         request_context
       ) do
    with {:ok, context} <-
           build_stateful_request_context(
             subject_uid,
             request,
             runtime,
             &Compaction.maybe_plan_history/6
           ),
         {:ok, message} <-
           StatefulResponses.start_planned_response_run(planned_run_attrs(context)) do
      stateful_context = response_stream_context(message)
      context = materialize_admitted_context(context, message)
      request_context = Map.put(request_context, "conversation_id", context.conversation.id)

      result =
        with {:ok, request_for_provider, run_attrs} <-
               provider_request_from_stateful_context(context, runtime),
             {:ok, message} <-
               StatefulResponses.merge_generating_response_metadata(
                 message,
                 run_attrs.metadata
               ),
             {:ok, %{spec: prepared_request}} <-
               ResponsesPreparation.prepare_with_runtime(
                 subject_uid,
                 runtime,
                 request_for_provider,
                 stream?: true,
                 request_context: request_context
               ) do
          recovery = %{
            request: context.request,
            runtime: runtime,
            request_context: request_context
          }

          {:ok, prepared_request, response_stream_context(message, recovery)}
        end

      case result do
        {:ok, _prepared_request, _stateful_context} = prepared ->
          prepared

        {:error, reason} = error ->
          commit_socket_open_error(stateful_context, reason)
          error
      end
    end
  end

  defp websocket_request_context(opts, request) do
    opts
    |> Keyword.get(:request_context, %{"downstream_transport" => "websocket"})
    |> Map.put("downstream_transport", "websocket")
    |> RequestContext.prepare(request)
  end

  defp put_run_conversation_id(request_context, %{conversation_id: conversation_id})
       when is_binary(conversation_id),
       do: Map.put(request_context, "conversation_id", conversation_id)

  defp put_run_conversation_id(request_context, _run_attrs), do: request_context

  defp build_stateful_request_context(subject_uid, request, runtime, compact_history) do
    conversation_id = request["conversation"]
    previous_response_id = request["previous_response_id"]

    with :ok <- ensure_stateful_replay_wire(runtime),
         :ok <- validate_external_optional_response_id(previous_response_id),
         {:ok, conversation} <-
           resolve_stateful_request_conversation(
             subject_uid,
             conversation_id,
             previous_response_id,
             public_request_metadata(request)
           ),
         :ok <- StatefulResponses.validate_response_anchor(conversation.id, previous_response_id),
         :ok <-
           maybe_ensure_implicit_response_run_available(
             conversation.id,
             previous_response_id
           ),
         effective_previous_response_id <-
           effective_previous_response_id(conversation.id, previous_response_id),
         {:ok, current_input} <- normalize_stateful_input(Map.get(request, "input")),
         history <-
           StatefulResponses.expand_history(conversation.id,
             previous_response_id: effective_previous_response_id,
             protected_tail_items: current_input
           ),
         {current_input, recovered_call_ids} <-
           recover_interrupted_tool_calls(history, current_input, previous_response_id),
         request <-
           request_with_effective_previous_response_id(request, effective_previous_response_id),
         {:ok, compaction} <-
           compact_history.(
             subject_uid,
             conversation.id,
             history,
             current_input,
             request,
             runtime
           ) do
      current_input =
        Compaction.maybe_inject_brain_pre_compaction_nudge(
          current_input,
          compaction.run_metadata
        )

      {:ok,
       %{
         subject_uid: subject_uid,
         conversation: conversation,
         explicit_previous_response_id: previous_response_id,
         request: request,
         current_input: current_input,
         recovered_call_ids: recovered_call_ids,
         compaction: compaction
       }}
    end
  end

  defp ensure_stateful_replay_wire(runtime) do
    provider_kind = Map.get(runtime, "provider_kind")

    with {:ok, api_resolver} <- Providers.effective_language_model_api_resolver(runtime) do
      if api_resolver in @stateful_replay_api_resolvers do
        :ok
      else
        {:error, {:stateful_wire_unsupported, provider_kind, api_resolver}}
      end
    end
  end

  defp maybe_ensure_implicit_response_run_available(
         conversation_id,
         nil
       ),
       do: StatefulResponses.ensure_implicit_response_run_available(conversation_id)

  defp maybe_ensure_implicit_response_run_available(
         _conversation_id,
         _explicit_previous_response_id
       ),
       do: :ok

  defp provider_request_from_stateful_context(context, runtime) do
    with {:ok, history_items} <-
           messages_to_response_items(
             context.subject_uid,
             context.compaction.history,
             runtime_input_modalities(runtime)
           ),
         {:ok, resolved_history_items} <-
           CompactionArtifacts.resolve_input_handles(
             context.subject_uid,
             history_items
           ),
         {provider_input, tool_result_quarantine} <-
           canonical_tool_result_projection(resolved_history_items ++ context.current_input),
         {:ok, expanded_input} <-
           CompactionArtifacts.resolve_input_handles(
             context.subject_uid,
             provider_input
           ) do
      provider_native_replay? =
        Enum.any?(resolved_history_items, &provider_native_replay_item?/1)

      provider_request =
        context.request
        |> Map.put("input", expanded_input)
        |> maybe_mark_stateful_provider_replay(provider_native_replay?)
        |> strip_stateful_provider_fields()

      {:ok, provider_request,
       %{
         subject_uid: context.subject_uid,
         conversation_id: context.conversation.id,
         previous_response_id: context.compaction.previous_response_id,
         request_items: context.current_input,
         metadata:
           stateful_run_metadata(
             context.request,
             context.compaction.run_metadata
           )
           |> maybe_put(
             "recovered_interrupted_tool_call_ids",
             context.recovered_call_ids,
             context.recovered_call_ids != []
           )
           |> maybe_put(
             "provider_projection_tool_result_quarantine",
             tool_result_quarantine,
             map_size(tool_result_quarantine) > 0
           )
       }}
    end
  end

  defp planned_run_attrs(context) do
    metadata =
      stateful_run_metadata(context.request, context.compaction.run_metadata)
      |> maybe_put(
        "recovered_interrupted_tool_call_ids",
        context.recovered_call_ids,
        context.recovered_call_ids != []
      )

    attrs = %{
      subject_uid: context.subject_uid,
      request_items: context.current_input,
      metadata: metadata,
      compaction: context.compaction.compaction
    }

    case context.explicit_previous_response_id do
      previous_response_id when is_binary(previous_response_id) ->
        Map.put(attrs, :previous_response_id, previous_response_id)

      _implicit ->
        attrs
        |> Map.put(:conversation_id, context.conversation.id)
        |> Map.put(
          :expected_previous_response_id,
          context.compaction.expected_previous_response_id
        )
    end
  end

  defp materialize_admitted_context(context, %Message{} = message) do
    previous_response_id =
      if is_binary(message.previous_message_id),
        do: "resp_#{message.previous_message_id}",
        else: nil

    compaction =
      if is_nil(context.compaction.compaction) do
        Map.put(context.compaction, :previous_response_id, previous_response_id)
      else
        run_metadata =
          Compaction.put_checkpoint_response_id(
            context.compaction.run_metadata,
            previous_response_id
          )

        context.compaction
        |> Map.put(
          :history,
          StatefulResponses.expand_history(context.conversation.id,
            previous_response_id: previous_response_id,
            protected_tail_items: context.current_input
          )
        )
        |> Map.put(:previous_response_id, previous_response_id)
        |> Map.put(:run_metadata, run_metadata)
      end

    %{context | compaction: compaction}
  end

  defp response_stream_context(%Message{} = message, recovery \\ nil) do
    context = %{
      message_id: message.id,
      message: message,
      subject_uid: message.subject_uid,
      conversation_id: message.conversation_id
    }

    if is_map(recovery), do: Map.put(context, :replay_recovery, recovery), else: context
  end

  defp stateful_run_metadata(request, compaction_metadata) do
    %{"request_metadata" => public_request_metadata(request)}
    |> Map.merge(Map.take(request, @stateful_request_metadata_fields))
    |> maybe_put("request_model", Map.get(request, "model"), true)
    |> Map.merge(compaction_metadata)
  end

  defp public_request_metadata(%{"metadata" => %{} = metadata}), do: metadata

  defp public_request_metadata(_request), do: %{}

  # A process crash can happen after a provider durably returns a client tool call
  # but before the worker journals its output. When AIGateway itself chooses the
  # latest conversation leaf, close those calls with explicit interrupted
  # outputs before replaying the actor input. Explicit previous_response_id
  # callers still own their continuation and are never rewritten here.
  defp recover_interrupted_tool_calls(_history, current_input, previous_response_id)
       when is_binary(previous_response_id),
       do: {current_input, []}

  defp recover_interrupted_tool_calls(history, current_input, _automatic_anchor) do
    history_items = Enum.flat_map(history, &message_content_items/1)
    output_pair_keys = paired_tool_call_output_keys(history_items ++ current_input)

    {interrupted_calls_rev, _seen_pairs} =
      Enum.reduce(history_items, {[], MapSet.new()}, fn item, {calls, seen_pairs} ->
        pair_key = ResponseItems.pair_key(item)

        if not recoverable_direct_tool_call?(item) or
             MapSet.member?(output_pair_keys, pair_key) or
             MapSet.member?(seen_pairs, pair_key) do
          {calls, seen_pairs}
        else
          {[item | calls], MapSet.put(seen_pairs, pair_key)}
        end
      end)

    interrupted_calls = Enum.reverse(interrupted_calls_rev)

    recovered_outputs = Enum.map(interrupted_calls, &interrupted_tool_output/1)
    {recovered_outputs ++ current_input, Enum.map(interrupted_calls, & &1["call_id"])}
  end

  defp message_content_items(%Message{content: content}) when is_list(content), do: content
  defp message_content_items(_message), do: []

  defp paired_tool_call_output_keys(items) do
    {_calls, outputs} =
      Enum.reduce(items, {%{}, MapSet.new()}, fn
        item, {calls, outputs} = acc ->
          cond do
            ResponseItems.client_call_item?(item) ->
              case ResponseItems.pair_key(item) do
                nil -> acc
                pair_key -> {Map.put(calls, pair_key, item), outputs}
              end

            ResponseItems.client_output_item?(item) ->
              pair_key = ResponseItems.pair_key(item)

              case Map.get(calls, pair_key) do
                nil ->
                  acc

                call ->
                  case ResponseItems.validate_client_call_output(call, item) do
                    :ok -> {calls, MapSet.put(outputs, pair_key)}
                    {:error, _reason} -> acc
                  end
              end

            true ->
              acc
          end
      end)

    outputs
  end

  # Durable rows remain an audit log. This projection is the stricter provider
  # view: a tool output is visible only after a matching executable call, and
  # only the first output for that call is replayed. Legacy orphan/duplicate
  # rows therefore cannot keep poisoning every later continuation.
  defp canonical_tool_result_projection(items) do
    {projected, _ledger, _projected_pairs, quarantine} =
      Enum.reduce(items, {[], ResponseItems.new(), MapSet.new(), %{}}, fn
        item, {projected, ledger, projected_pairs, quarantine} ->
          cond do
            ResponseItems.call_item?(item) ->
              project_call_item(item, projected, ledger, projected_pairs, quarantine)

            ResponseItems.output_item?(item) ->
              project_output_item(item, projected, ledger, projected_pairs, quarantine)

            true ->
              {[item | projected], ledger, projected_pairs, quarantine}
          end
      end)

    {Enum.reverse(projected), finalize_quarantine(quarantine)}
  end

  defp project_call_item(item, projected, ledger, projected_pairs, quarantine) do
    case ResponseItems.reduce_with_key(ledger, item) do
      {:ok, ledger, :inserted, pair_key} ->
        if ResponseItems.executable_in_ledger?(ledger, item) do
          {[item | projected], ledger, MapSet.put(projected_pairs, pair_key), quarantine}
        else
          {projected, ledger, projected_pairs, quarantine_non_executable_call(quarantine, item)}
        end

      {:ok, ledger, :duplicate, _pair_key} ->
        {projected, ledger, projected_pairs,
         quarantine_pair_id(quarantine, "duplicate_call_ids", item)}

      {:error, _reason} ->
        {projected, ledger, projected_pairs,
         increment_quarantine_count(quarantine, "invalid_tool_call_count")}
    end
  end

  defp project_output_item(item, projected, ledger, projected_pairs, quarantine) do
    case ResponseItems.reduce_with_key(ledger, item) do
      {:ok, ledger, :inserted, pair_key} ->
        case ResponseItems.call_for_pair(ledger, pair_key) do
          nil ->
            {projected, ledger, projected_pairs,
             quarantine_pair_id(quarantine, "orphan_call_ids", item)}

          call ->
            if MapSet.member?(projected_pairs, pair_key) and
                 ResponseItems.executable_in_ledger?(ledger, call) do
              {[item | projected], ledger, projected_pairs, quarantine}
            else
              {projected, ledger, projected_pairs,
               quarantine_pair_id(quarantine, "non_executable_call_ids", item)}
            end
        end

      {:ok, ledger, :duplicate, _pair_key} ->
        {projected, ledger, projected_pairs,
         quarantine_pair_id(quarantine, "duplicate_call_ids", item)}

      {:error, {:orphan_call_output, _pair_key, _type}} ->
        {projected, ledger, projected_pairs,
         quarantine_pair_id(quarantine, "orphan_call_ids", item)}

      {:error, :orphan_server_tool_search_output} ->
        {projected, ledger, projected_pairs,
         quarantine_pair_id(quarantine, "orphan_call_ids", item)}

      {:error, {:mismatched_call_output, _pair_key, _expected_type}} ->
        {projected, ledger, projected_pairs,
         quarantine_pair_id(quarantine, "type_mismatch_call_ids", item)}

      {:error, {:mismatched_call_output_name, _pair_key}} ->
        {projected, ledger, projected_pairs,
         quarantine_pair_id(quarantine, "name_mismatch_call_ids", item)}

      {:error, {:conflicting_output_pair, _pair_key, _existing_type, _received_type}} ->
        {projected, ledger, projected_pairs,
         quarantine_pair_id(quarantine, "duplicate_call_ids", item)}

      {:error, _reason} ->
        {projected, ledger, projected_pairs,
         increment_quarantine_count(quarantine, "invalid_call_id_count")}
    end
  end

  defp recoverable_direct_tool_call?(item) do
    ResponseItems.client_call_item?(item) and
      ResponseItems.executable_call?(item) and
      match?({:call, :direct, _call_id}, ResponseItems.pair_key(item))
  end

  defp append_quarantine_id(quarantine, key, call_id) do
    Map.update(quarantine, key, MapSet.new([call_id]), &MapSet.put(&1, call_id))
  end

  defp finalize_quarantine(quarantine) do
    Map.new(quarantine, fn
      {key, %MapSet{} = call_ids} -> {key, call_ids |> Enum.to_list() |> Enum.sort()}
      entry -> entry
    end)
  end

  defp increment_quarantine_count(quarantine, key) do
    Map.update(quarantine, key, 1, &(&1 + 1))
  end

  defp quarantine_non_executable_call(quarantine, item) do
    case pair_reference(item) do
      nil -> increment_quarantine_count(quarantine, "invalid_tool_call_count")
      pair_id -> append_quarantine_id(quarantine, "non_executable_call_ids", pair_id)
    end
  end

  defp quarantine_pair_id(quarantine, key, item) do
    case pair_reference(item) do
      nil -> increment_quarantine_count(quarantine, "invalid_call_id_count")
      pair_id -> append_quarantine_id(quarantine, key, pair_id)
    end
  end

  defp pair_reference(item) do
    Enum.find_value(["call_id", "provider_call_id", "id"], fn key ->
      case Map.get(item, key) do
        value when is_binary(value) and value != "" -> value
        _missing -> nil
      end
    end)
  end

  defp interrupted_tool_output(%{"type" => type, "call_id" => call_id}) do
    %{
      "type" => ResponseItems.client_expected_output_type(type),
      "call_id" => call_id,
      "output" =>
        Ankole.JSON.encode!(%{
          "error" => %{
            "code" => "tool_execution_interrupted",
            "message" =>
              "The tool process stopped before its result was durably recorded. Treat this call as failed and retry it if the task still requires it."
          }
        })
    }
  end

  defp resolve_stateful_request_conversation(
         subject_uid,
         conversation_id,
         _previous_response_id,
         _metadata
       )
       when not is_nil(conversation_id) do
    with :ok <- validate_external_conversation_id(conversation_id) do
      StatefulResponses.get_conversation_for_subject(subject_uid, decode_conv_id(conversation_id))
    end
  end

  defp resolve_stateful_request_conversation(subject_uid, nil, nil, metadata),
    do:
      StatefulResponses.create_managed_stateful_responses_conversation(subject_uid,
        metadata: metadata
      )

  defp resolve_stateful_request_conversation(
         subject_uid,
         nil,
         previous_response_id,
         _metadata
       ) do
    case StatefulResponses.get_message(previous_response_id) do
      %{status: "complete", conversation_id: conversation_id} ->
        case StatefulResponses.get_conversation_for_subject(subject_uid, conversation_id) do
          {:ok, conversation} -> {:ok, conversation}
          {:error, :invalid_conversation} -> {:error, :invalid_anchor}
        end

      _missing_or_not_complete ->
        {:error, :invalid_anchor}
    end
  end

  # Consume internal AIGateway state fields before provider dispatch. These are
  # Ankole continuation controls, not upstream provider request parameters.
  defp strip_stateful_provider_fields(request) do
    request
    |> Map.delete("previous_response_id")
    |> Map.delete("store")
    |> Map.delete("conversation")
    |> Map.delete("service_tier")
  end

  defp decode_conv_id("conv_" <> uuid), do: uuid

  defp effective_previous_response_id(_conversation_id, previous_response_id)
       when is_binary(previous_response_id),
       do: previous_response_id

  defp effective_previous_response_id(conversation_id, _missing_previous_response_id) do
    case StatefulResponses.latest_visible_leaf(conversation_id) do
      nil -> nil
      message_id -> "resp_#{message_id}"
    end
  end

  defp request_with_effective_previous_response_id(request, nil), do: request

  defp request_with_effective_previous_response_id(request, previous_response_id),
    do: Map.put(request, "previous_response_id", previous_response_id)

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, _key, nil, true), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp socket_open_error_details(reason) do
    classification = FailureDiagnostics.classify(reason)
    code = Map.get(classification, :error_code, "provider_call_failed")

    %{
      "code" => code,
      "message" => FailureDiagnostics.public_message(classification),
      "stage" => "socket_open",
      "retryable" => Map.get(classification, :retryable, false)
    }
    |> put_safe_failure_fields(classification)
    |> maybe_put_pool_retry_at(reason)
  end

  defp maybe_put_pool_retry_at(details, {:credential_pool_exhausted, %{"retry_at" => retry_at}})
       when is_binary(retry_at),
       do: Map.put(details, "retry_at", retry_at)

  defp maybe_put_pool_retry_at(details, _reason), do: details

  defp put_safe_failure_fields(details, classification) do
    classification
    |> Map.take([
      :error_stage,
      :failure_kind,
      :http_status,
      :provider_error_code,
      :provider_error_type,
      :provider_status,
      :retryable
    ])
    |> Enum.reduce(details, fn {key, value}, acc ->
      Map.put(acc, Atom.to_string(key), safe_failure_value(value))
    end)
  end

  defp safe_failure_value(value) when is_boolean(value), do: value
  defp safe_failure_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_failure_value(value), do: value

  # The message log stores durable Response items directly. Do not re-derive
  # history from the legacy row-level role hint. Provider-facing replay strips
  # optional opaque item ids because this gateway uses store=false upstream and
  # owns continuation through its local `resp_*` chain. Responses input items
  # whose wire contract requires an id must keep it.
  defp messages_to_response_items(subject_uid, messages, input_modalities) do
    supports_image? = "image" in input_modalities

    messages
    |> Enum.reduce_while({:ok, []}, fn message, {:ok, chunks} ->
      case message_response_items(subject_uid, message) do
        {:ok, items, :provider_native} ->
          {:cont, {:ok, [items | chunks]}}

        {:ok, items, :standard} ->
          replay_items = Enum.map(items, &provider_replay_item(&1, supports_image?))
          {:cont, {:ok, [replay_items | chunks]}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, chunks} ->
        {:ok, chunks |> Enum.reverse() |> List.flatten()}

      {:error, _reason} = error ->
        error
    end
  end

  defp message_response_items(subject_uid, %Message{type: "checkpoint"} = message) do
    with {:ok, content} <- CompactionArtifacts.content_for_checkpoint(subject_uid, message),
         output when is_list(output) <- Map.get(content, "output") do
      projection =
        if Map.get(content, "version") == 3,
          do: :provider_native,
          else: :standard

      {:ok, output, projection}
    else
      _invalid -> {:error, :invalid_compaction_handle}
    end
  end

  defp message_response_items(_subject_uid, %{content: content}) when is_list(content),
    do: {:ok, content, :standard}

  defp message_response_items(_subject_uid, _message), do: {:ok, [], :standard}

  defp provider_replay_item(%{"id" => id} = item, _supports_image?)
       when is_binary(id) and id != "" and map_size(item) == 1,
       do: Map.put(item, "type", "item_reference")

  defp provider_replay_item(%{"id" => id, "type" => nil} = item, _supports_image?)
       when is_binary(id) and id != "" and map_size(item) == 2,
       do: Map.put(item, "type", "item_reference")

  defp provider_replay_item(
         %{"type" => "message", "role" => "assistant", "status" => status, "id" => id} = item,
         _supports_image?
       )
       when status in ["in_progress", "completed", "incomplete"] and is_binary(id) and id != "",
       do: item

  defp provider_replay_item(%{} = item, supports_image?)
       when is_map_key(item, "id") do
    cond do
      ResponseItems.provider_replay_id_required?(item) -> item
      supports_image? -> Map.delete(item, "id")
      true -> item |> Map.delete("id") |> replace_image_parts_for_text_model()
    end
  end

  defp provider_replay_item(%{} = item, true), do: Map.delete(item, "id")

  defp provider_replay_item(%{} = item, false) do
    item
    |> Map.delete("id")
    |> replace_image_parts_for_text_model()
  end

  defp provider_replay_item(item, _supports_image?), do: item

  defp provider_native_replay_item?(%{"id" => id} = item)
       when is_binary(id) and id != "",
       do: ResponseItems.provider_replay_id_required?(item)

  defp provider_native_replay_item?(%{} = item), do: provider_ciphertext?(item)
  defp provider_native_replay_item?(_item), do: false

  defp provider_ciphertext?(%{"type" => "reasoning", "encrypted_content" => content})
       when is_binary(content) and content != "",
       do: true

  defp provider_ciphertext?(%{"type" => "encrypted_content"}), do: true

  defp provider_ciphertext?(%{} = value) do
    Map.has_key?(value, "encrypted_function_args") or
      Enum.any?(value, fn {_key, nested} -> provider_ciphertext?(nested) end)
  end

  defp provider_ciphertext?(value) when is_list(value),
    do: Enum.any?(value, &provider_ciphertext?/1)

  defp provider_ciphertext?(_value), do: false

  defp maybe_mark_stateful_provider_replay(request, true),
    do: Map.put(request, @stateful_provider_replay_marker, true)

  defp maybe_mark_stateful_provider_replay(request, false), do: request

  defp response_id(id) when is_binary(id), do: "resp_#{id}"
  defp response_id(_id), do: nil

  defp replace_image_parts_for_text_model(%{"type" => type})
       when type in ["input_image", "image_url", "image"] do
    %{"type" => "input_text", "text" => "[image removed: current model has no image input]"}
  end

  defp replace_image_parts_for_text_model(%{"content" => content} = item) when is_list(content) do
    Map.put(item, "content", Enum.map(content, &replace_image_parts_for_text_model/1))
  end

  defp replace_image_parts_for_text_model(item), do: item

  defp runtime_input_modalities(%{"provider" => provider, "model" => model})
       when is_binary(model) do
    case ModelMetadata.model_metadata(provider, model) do
      {:ok, %{"architecture" => %{"input_modalities" => modalities}}} when is_list(modalities) ->
        Enum.map(modalities, &to_string/1)

      _metadata ->
        ["text"]
    end
  end

  defp runtime_input_modalities(_runtime), do: ["text"]

  defp response_resource(%Message{} = message) do
    metadata = if is_map(message.metadata), do: message.metadata, else: %{}
    content = response_content(message)

    with {:ok, content} <- Artifacts.hydrate_generated_images(message.subject_uid, content) do
      {input, output} = response_input_and_output(message.status, content, metadata)

      {:ok,
       %{
         "id" => "resp_#{message.id}",
         "object" => "response",
         "created_at" => unix_timestamp(message.inserted_at),
         "completed_at" => response_completed_at(message),
         "status" => response_status(message.status, metadata),
         "incomplete_details" => response_incomplete_details(message.status, metadata),
         "model" => response_model(metadata),
         "previous_response_id" => prefixed_id("resp_", message.previous_message_id),
         "instructions" => Map.get(metadata, "instructions"),
         "input" => input,
         "output" => output,
         "error" => response_error(message.status, metadata),
         "tools" => list_or_empty(Map.get(metadata, "tools")),
         "tool_choice" => Map.get(metadata, "tool_choice", "auto"),
         "truncation" => Map.get(metadata, "truncation", "disabled"),
         "parallel_tool_calls" => Map.get(metadata, "parallel_tool_calls", true),
         "text" => Map.get(metadata, "text", %{"format" => %{"type" => "text"}}),
         "top_p" => Map.get(metadata, "top_p", 1),
         "presence_penalty" => Map.get(metadata, "presence_penalty", 0),
         "frequency_penalty" => Map.get(metadata, "frequency_penalty", 0),
         "top_logprobs" => Map.get(metadata, "top_logprobs", 0),
         "temperature" => Map.get(metadata, "temperature", 1),
         "reasoning" => Map.get(metadata, "reasoning", %{"effort" => nil, "summary" => nil}),
         "usage" => response_usage(Map.get(metadata, "usage")),
         "tool_usage" => map_or_empty(Map.get(metadata, "tool_usage")),
         "provider_metadata" => map_or_empty(Map.get(metadata, "provider_metadata")),
         "tool_results" => list_or_empty(Map.get(metadata, "tool_results")),
         "stop_reason" => Map.get(metadata, "stop_reason"),
         "max_output_tokens" => Map.get(metadata, "max_output_tokens"),
         "max_tool_calls" => Map.get(metadata, "max_tool_calls"),
         "store" => true,
         "background" => false,
         "service_tier" => Map.get(metadata, "service_tier"),
         "metadata" => public_response_metadata(metadata),
         "safety_identifier" => Map.get(metadata, "safety_identifier"),
         "prompt_cache_key" => Map.get(metadata, "prompt_cache_key"),
         "user" => Map.get(metadata, "user"),
         "next_response_ids" => [],
         "context_edits" => [],
         "prompt_cache_retention" => nil,
         "conversation" => %{"id" => "conv_#{message.conversation_id}"}
       }}
    end
  end

  defp response_content(%Message{type: "checkpoint"} = message) do
    case CompactionArtifacts.output_for_checkpoint(message.subject_uid, message) do
      {:ok, content} -> content
      {:error, _reason} -> []
    end
  end

  defp response_content(%Message{content: content}) when is_list(content), do: content
  defp response_content(_message), do: []

  defp input_item?(item) when is_map(item) do
    ResponseItems.client_output_item?(item) or input_message_item?(item)
  end

  defp input_item?(_item), do: false

  defp input_message_item?(%{"type" => "message", "role" => role})
       when role in @input_message_roles,
       do: true

  defp input_message_item?(%{"role" => role}) when role in @input_message_roles,
    do: true

  defp input_message_item?(_item), do: false

  defp output_item?(item), do: not input_item?(item)

  defp response_input_and_output(status, content, %{"request_item_count" => count})
       when is_list(content) and is_integer(count) and count >= 0 do
    input = Enum.take(content, count)
    output = if status == "generating", do: [], else: Enum.drop(content, count)
    {input, output}
  end

  defp response_input_and_output("generating", content, _metadata),
    do: {Enum.filter(content, &input_item?/1), []}

  defp response_input_and_output(_status, content, _metadata),
    do: {Enum.filter(content, &input_item?/1), Enum.filter(content, &output_item?/1)}

  defp response_completed_at(%Message{status: status, updated_at: updated_at})
       when status in ["complete", "error", "retracted"],
       do: unix_timestamp(updated_at)

  defp response_completed_at(_message), do: nil

  defp response_status("generating", _metadata), do: "in_progress"

  defp response_status("complete", %{"response" => %{"status" => "incomplete"}}),
    do: "incomplete"

  defp response_status("complete", %{"incomplete_details" => %{} = _details}),
    do: "incomplete"

  defp response_status("complete", _metadata), do: "completed"
  defp response_status("error", _metadata), do: "failed"
  defp response_status("retracted", _metadata), do: "failed"
  defp response_status(_status, _metadata), do: "failed"

  defp response_incomplete_details("complete", %{"incomplete_details" => details})
       when not is_nil(details),
       do: details

  defp response_incomplete_details(_status, _metadata), do: nil

  defp response_model(%{"provider_model" => model}) when is_binary(model) and model != "",
    do: model

  defp response_model(%{"model_ref" => %{"model" => model}})
       when is_binary(model) and model != "", do: model

  defp response_model(%{"request_model" => model}) when is_binary(model) and model != "",
    do: model

  defp response_model(%{"model" => model}) when is_binary(model) and model != "", do: model

  defp response_model(_metadata), do: "unknown"

  defp response_error("error", %{"error" => %{} = error}) do
    classification = FailureDiagnostics.classify_stored(error)

    %{
      "code" => Map.get(classification, :error_code, "error"),
      "message" => FailureDiagnostics.public_message(classification)
    }
    |> put_safe_failure_fields(classification)
  end

  defp response_error("error", _metadata),
    do: %{"code" => "error", "message" => "response failed"}

  defp response_error("retracted", _metadata),
    do: %{"code" => "retracted", "message" => "response was retracted"}

  defp response_error(_status, _metadata), do: nil

  defp response_usage(%{} = usage) do
    input_tokens = usage_integer(usage, ["input_tokens", "prompt_tokens", "inputTokens"])
    output_tokens = usage_integer(usage, ["output_tokens", "completion_tokens", "outputTokens"])

    total_tokens =
      usage_integer(usage, ["total_tokens", "totalTokens"], input_tokens + output_tokens)

    %{
      "input_tokens" => input_tokens,
      "output_tokens" => output_tokens,
      "total_tokens" => total_tokens,
      "input_tokens_details" => %{
        "cached_tokens" =>
          usage_integer(
            map_or_empty(
              Map.get(usage, "input_tokens_details") || Map.get(usage, "prompt_tokens_details")
            ),
            ["cached_tokens", "cached", "cachedInputTokens"]
          )
      },
      "output_tokens_details" => %{
        "reasoning_tokens" =>
          usage_integer(
            map_or_empty(
              Map.get(usage, "output_tokens_details") ||
                Map.get(usage, "completion_tokens_details")
            ),
            ["reasoning_tokens", "reasoning", "reasoningTokens"]
          )
      }
    }
  end

  defp response_usage(_usage) do
    %{
      "input_tokens" => 0,
      "output_tokens" => 0,
      "total_tokens" => 0,
      "input_tokens_details" => %{"cached_tokens" => 0},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end

  defp public_response_metadata(metadata) do
    case Map.get(metadata, "request_metadata") do
      %{} = request_metadata -> request_metadata
      _missing -> %{}
    end
  end

  defp list_or_empty(value) when is_list(value), do: value
  defp list_or_empty(_value), do: []

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  defp usage_integer(map, keys, default \\ 0)

  defp usage_integer(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _value -> false
      end
    end)
  end

  defp usage_integer(_map, _keys, default), do: default

  defp prefixed_id(_prefix, nil), do: nil
  defp prefixed_id(prefix, id) when is_binary(id), do: prefix <> id

  defp unix_timestamp(%DateTime{} = datetime), do: DateTime.to_unix(datetime)
  defp unix_timestamp(_datetime), do: nil

  defp validate_external_optional_response_id(nil), do: :ok
  defp validate_external_optional_response_id(value), do: validate_external_response_id(value)

  defp validate_external_response_id("resp_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_anchor}
    end
  end

  defp validate_external_response_id(_value), do: {:error, :invalid_anchor}

  defp validate_external_conversation_id("conv_" <> uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_conversation}
    end
  end

  defp validate_external_conversation_id(_value), do: {:error, :invalid_conversation}

  defp validate_websocket_stateful_shape(request) do
    request = normalize_request_keys(request)
    previous_response_id = Map.get(request, "previous_response_id")
    conversation_id = Map.get(request, "conversation")

    continuation_field =
      Enum.find(@websocket_continuation_fields, &(not is_nil(Map.get(request, &1))))

    cond do
      not is_nil(previous_response_id) and not is_nil(conversation_id) ->
        {:error, :stateful_anchor_conflict}

      not is_nil(previous_response_id) &&
          validate_external_response_id(previous_response_id) != :ok ->
        {:error, :invalid_anchor}

      not is_nil(conversation_id) && validate_external_conversation_id(conversation_id) != :ok ->
        {:error, :invalid_conversation}

      continuation_field && request["store"] != true ->
        {:error, :stateful_store_required}

      not valid_max_tool_calls?(Map.get(request, "max_tool_calls")) ->
        {:error, :invalid_max_tool_calls}

      not valid_stateful_input?(Map.get(request, "input")) ->
        {:error, :invalid_input}

      true ->
        :ok
    end
  end

  defp validate_tool_results_record_shape(request) do
    request = normalize_request_keys(request)
    previous_response_id = Map.get(request, "previous_response_id")

    cond do
      is_nil(previous_response_id) ->
        {:error, :missing_stateful_anchor}

      validate_external_response_id(previous_response_id) != :ok ->
        {:error, :invalid_anchor}

      not valid_stateful_input?(Map.get(request, "input")) ->
        {:error, :invalid_input}

      true ->
        :ok
    end
  end

  defp valid_max_tool_calls?(nil), do: true
  defp valid_max_tool_calls?(value) when is_integer(value), do: value >= 0
  defp valid_max_tool_calls?(_value), do: false

  defp valid_stateful_input?(nil), do: true
  defp valid_stateful_input?(value) when is_binary(value), do: true
  defp valid_stateful_input?(value) when is_list(value), do: true
  defp valid_stateful_input?(_value), do: false

  defp normalize_stateful_input(nil), do: {:ok, []}
  defp normalize_stateful_input(input) when is_list(input), do: {:ok, input}

  defp normalize_stateful_input(input) when is_binary(input) do
    {:ok,
     [
       %{
         "type" => "message",
         "role" => "user",
         "content" => [%{"type" => "input_text", "text" => input}]
       }
     ]}
  end

  defp normalize_stateful_input(_input), do: {:error, :invalid_input}

  defp tool_result_record_attrs(subject_uid, request, internal_metadata) do
    request = normalize_request_keys(request)
    previous_response_id = request["previous_response_id"]

    with :ok <- validate_tool_results_record_shape(request),
         {:ok, current_input} <- normalize_stateful_input(Map.get(request, "input")) do
      {:ok,
       %{
         subject_uid: subject_uid,
         previous_response_id: previous_response_id,
         request_items: current_input,
         metadata: Map.merge(stateful_run_metadata(request, %{}), internal_metadata)
       }}
    end
  end

  defp record_tool_results_with_transient_db_retry(attrs) do
    with_transient_db_checkout_retry(@tool_result_record_db_retry_delays_ms, fn ->
      StatefulResponses.record_tool_results(attrs)
    end)
  end

  defp with_transient_db_checkout_retry(delays_ms, fun) do
    fun.()
  rescue
    error in DBConnection.ConnectionError ->
      if transient_db_checkout_error?(error) do
        retry_transient_db_checkout(delays_ms, Exception.message(error), fun)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp retry_transient_db_checkout([delay_ms | rest], _message, fun) do
    Process.sleep(delay_ms)
    with_transient_db_checkout_retry(rest, fun)
  end

  defp retry_transient_db_checkout([], message, _fun) do
    {:error,
     {:tool_results_record_unavailable,
      %{
        "stage" => "tool_results_record",
        "retryable" => true,
        "message" => message
      }}}
  end

  defp transient_db_checkout_error?(%DBConnection.ConnectionError{} = error) do
    message = Exception.message(error)

    String.contains?(message, "could not checkout the connection") and
      String.contains?(message, "connection not available")
  end

  defp normalize_request_keys(map), do: MapUtils.normalize_request_keys(map)
end
