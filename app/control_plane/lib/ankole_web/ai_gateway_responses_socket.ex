defmodule AnkoleWeb.AIGatewayResponsesSocket do
  @moduledoc """
  OpenResponses WebSocket transport for AIGateway.

  Supports both stateless and stateful (`store=true`) response.create runs.
  For stateful runs, a generating `ai_gateway_messages` row is created before
  the provider call, and committed (complete/error) when the stream finishes.

  Provider stream frames are parsed into typed semantic events that feed three
  consumers simultaneously:
    1. **Client forwarding** — raw JSON text pushed to the WebSocket client.
    2. **Terminal content accumulation** — completed Response items held in
       process memory until the terminal commit.
    3. **Typed live chunk publishing** — generic semantic events published on
       the owning AIGateway conversation.

  Response ID rewriting: every stateful frame with `response.id` or top-level
  `response_id` has it rewritten from the provider's raw id to
  `resp_{message_id}` before forwarding to the client (plan §1.4 — provider ids
  must not become stored ids).
  """

  @behaviour WebSock

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.MaxToolCalls
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Kernel.UniversalAIClient
  alias Ankole.Logging

  @socket_response_history_limit 32
  @response_heartbeat_ms 60_000

  # ─────────────────────────────────────────────────────────────────
  # Connection lifecycle
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def init(%{subject_uid: subject_uid, subject_type: subject_type}) do
    {:ok, %{subject_uid: subject_uid, subject_type: subject_type}}
  end

  # ─────────────────────────────────────────────────────────────────
  # Incoming: response.create
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def handle_in({payload, [opcode: :text]}, state) do
    result =
      with :ok <- ensure_no_active_stream(state),
           {:ok, event} <- decode_socket_event(payload, state) do
        handle_socket_event(event, state)
      end

    case result do
      {:error, %{event: event, state: error_state}} ->
        {:push, {:text, Ankole.JSON.encode!(event)}, error_state}

      {:error, :invalid_anchor} ->
        event =
          error_event(
            400,
            "invalid_previous_response_id",
            "previous_response_id does not reference a valid complete message in this conversation."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :previous_response_not_found} ->
        event =
          error_event(
            400,
            "previous_response_not_found",
            "previous_response_id was not found on this WebSocket connection.",
            "previous_response_id"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :invalid_conversation} ->
        event =
          error_event(
            400,
            "invalid_stateful_conversation",
            "conversation does not reference an active conversation owned by this subject."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :missing_stateful_anchor} ->
        event =
          error_event(
            400,
            "stateful_anchor_required",
            "previous_response_id is required for this stateful Responses operation.",
            "previous_response_id"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :stateful_anchor_conflict} ->
        event =
          error_event(
            400,
            "stateful_anchor_conflict",
            "previous_response_id and conversation are mutually exclusive."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :stateful_store_required} ->
        event =
          error_event(
            400,
            "stateful_store_required",
            "previous_response_id and conversation require explicit store=true on WebSocket response.create."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :invalid_input} ->
        event =
          error_event(
            400,
            "invalid_input",
            "input must be a string or an array of Response input items.",
            "input"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :invalid_tool_results} ->
        event =
          error_event(
            400,
            "invalid_tool_results",
            "response.tool_results.record requires at least one function_call_output item.",
            "input"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :invalid_max_tool_calls} ->
        event =
          error_event(
            400,
            "invalid_max_tool_calls",
            "max_tool_calls must be a non-negative integer.",
            "max_tool_calls"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :response_run_in_progress} ->
        event =
          error_event(
            409,
            "response_in_progress",
            "This response already has an active stateful run."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:context_overflow, details}} ->
        event =
          error_event(
            422,
            "context_overflow",
            "AIGateway stateful input exceeds the configured context budget.",
            nil,
            details
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:upstream_response_failed, status, body}} ->
        event = upstream_response_failed_event(status, body)
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:invalid_upstream_response, status, body}} ->
        event =
          error_event(
            502,
            "invalid_upstream_response",
            "Provider returned an invalid upstream response.",
            nil,
            %{"stage" => "socket_open", "upstream_status" => status, "upstream_body" => body}
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:universal_ai_request_failed, %{} = details}} ->
        event = universal_ai_request_failed_event(details)
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:tool_results_record_unavailable, %{} = details}} ->
        event =
          error_event(
            503,
            "tool_results_record_unavailable",
            "AIGateway could not persist tool results before the retry budget was exhausted.",
            nil,
            details
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, reason} ->
        event = error_event(422, "ai_gateway_request_failed", inspect(reason))
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      other ->
        other
    end
  end

  def handle_in({_payload, [opcode: :binary]}, state) do
    event =
      error_event(
        400,
        "invalid_request_error",
        "AIGateway Responses WebSocket accepts only JSON text frames."
      )

    {:push, {:text, Ankole.JSON.encode!(event)}, state}
  end

  defp handle_socket_event(%{"type" => "response.create"} = event, state) do
    with {:ok, request, socket_context} <-
           prepare_response_create_request(state, prepare_request(event)),
         {:ok, active_stream} <- open_active_stream(state, request) do
      active_stream = Map.merge(active_stream, socket_context)
      {:ok, Map.put(state, :active_stream, active_stream)}
    end
  end

  defp handle_socket_event(%{"type" => "response.tool_results.record"} = event, state) do
    request = prepare_request(event)

    case AIGateway.record_tool_results(state.subject_uid, request) do
      {:ok, %{body: body}} ->
        event = tool_results_recorded_event(body)
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, _reason} = error ->
        error
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Provider stream events
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def handle_info(
        {:universal_ai_client, ref, :chunk, seq, :websocket_text, chunk},
        %{active_stream: %{ref: ref, stream: stream, stateful: stateful} = active} = state
      ) do
    # Parse the provider frame to extract completed items + typed events.
    # The raw chunk is still forwarded to the client unmodified (except for
    # response ID rewriting on terminal frames, handled in :done/:error).
    {new_active, client_chunk} = process_provider_chunk(active, chunk, seq)

    # Publish typed live events for stateful runs.
    maybe_publish_typed_events(stateful, active, new_active, seq)

    cond do
      Map.get(new_active, :terminal_received, false) ->
        state =
          state
          |> remember_socket_response(new_active)
          |> clear_active_stream()

        {:push, {:text, client_chunk}, state}

      MaxToolCalls.stop?(Map.get(new_active, :max_tool_calls)) ->
        stop_for_max_tool_calls(state, new_active, client_chunk)

      true ->
        case UniversalAIClient.read(stream, 1) do
          :ok ->
            {:push, {:text, client_chunk}, Map.put(state, :active_stream, new_active)}

          {:error, reason} ->
            case fail_active_stream(
                   state,
                   new_active,
                   "stream_read_failed: #{inspect(reason)}",
                   code: "provider_stream_error",
                   retryable: true
                 ) do
              {:push, failed_chunk, state} ->
                {:push, [{:text, client_chunk}, {:text, failed_chunk}], state}

              {:ok, state} ->
                {:push, {:text, client_chunk}, state}
            end
        end
    end
  end

  def handle_info(
        {:universal_ai_client, ref, :chunk, _seq, kind, _chunk},
        %{active_stream: %{ref: ref, stream: stream, stateful: stateful} = active} = state
      ) do
    _ = UniversalAIClient.cancel(stream)

    commit_stateful_error(
      stateful,
      "unexpected_chunk_kind: #{inspect(kind)}",
      unpersisted_items(active),
      code: "unexpected_downstream_chunk_kind",
      retryable: true
    )

    event =
      error_event(
        502,
        "unexpected_downstream_chunk_kind",
        "UniversalAIClient stream produced #{inspect(kind)} for WebSocket transport"
      )

    {:push, {:text, Ankole.JSON.encode!(event)}, clear_active_stream(state)}
  end

  # Stream completed successfully.
  @impl WebSock
  def handle_info(
        {:universal_ai_client, ref, :done, _summary},
        %{active_stream: %{ref: ref, stateful: stateful} = active} = state
      ) do
    if Map.get(active, :terminal_committed, false) or
         Map.get(active, :terminal_received, false) do
      {:ok, clear_active_stream(state)}
    else
      case fail_active_stream(
             state,
             %{active | stateful: stateful},
             "provider_stream_closed_without_terminal",
             code: "provider_stream_closed_without_terminal",
             retryable: true
           ) do
        {:push, failed_chunk, state} -> {:push, {:text, failed_chunk}, state}
        {:ok, state} -> {:ok, state}
      end
    end
  end

  # Stream errored.
  def handle_info(
        {:universal_ai_client, ref, :error, error},
        %{active_stream: %{ref: ref} = active} = state
      ) do
    case fail_active_stream(
           state,
           active,
           "provider_stream_error: #{inspect(error)}",
           code: "provider_stream_error",
           retryable: true
         ) do
      {:push, failed_chunk, state} -> {:push, {:text, failed_chunk}, state}
      {:ok, state} -> {:ok, state}
    end
  end

  # Stream aborted (e.g. client disconnect, timeout).
  def handle_info(
        {:universal_ai_client, ref, :aborted},
        %{active_stream: %{ref: ref} = active} = state
      ) do
    case fail_active_stream(state, active, "stream_aborted",
           code: "provider_stream_aborted",
           retryable: true
         ) do
      {:push, failed_chunk, state} -> {:push, {:text, failed_chunk}, state}
      {:ok, state} -> {:ok, state}
    end
  end

  def handle_info({:universal_ai_client, _ref, _kind, _payload}, state), do: {:ok, state}
  def handle_info({:universal_ai_client, _ref, _kind}, state), do: {:ok, state}

  def handle_info({:universal_ai_client, _ref, _kind, _seq, _chunk_kind, _binary}, state),
    do: {:ok, state}

  def handle_info(
        {:ai_gateway_response_heartbeat, ref},
        %{
          subject_uid: subject_uid,
          active_stream: %{ref: ref, stateful: %{message_id: message_id}}
        } = state
      ) do
    case StatefulResponses.touch_generating_response(subject_uid, message_id) do
      {:ok, %{} = _message} -> schedule_response_heartbeat(ref)
      {:ok, :already_terminal} -> :ok
      {:error, _reason} -> :ok
    end

    {:ok, state}
  end

  def handle_info({:ai_gateway_response_heartbeat, _stale_ref}, state), do: {:ok, state}

  def handle_info(_message, state), do: {:ok, state}

  # ─────────────────────────────────────────────────────────────────
  # Termination — clean up any leaking generating row
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def terminate(_reason, %{active_stream: %{stream: stream, stateful: stateful} = active}) do
    _ = UniversalAIClient.cancel(stream)

    commit_stateful_error(stateful, "socket_terminated", unpersisted_items(active),
      code: "socket_terminated",
      retryable: true
    )

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ─────────────────────────────────────────────────────────────────
  # Provider chunk processing
  # ─────────────────────────────────────────────────────────────────

  # Parses a provider WebSocket text chunk into structured events.
  # Extracts completed Response items (held in process memory until terminal
  # commit) and typed semantic events (for live PubSub publishing).
  #
  # Returns {updated_active, client_chunk} where client_chunk is what gets
  # forwarded to the worker/client.
  defp process_provider_chunk(active, chunk_binary, seq) do
    chunk_string = IO.iodata_to_binary(chunk_binary)

    # Try to parse as JSON (provider WebSocket frames are SSE-like JSON objects).
    case Ankole.JSON.decode(chunk_string) do
      {:ok, chunk_json} when is_map(chunk_json) ->
        {active, client_chunk} = handle_parsed_chunk(active, chunk_json, seq, chunk_string)
        {active, client_chunk}

      {:ok, _} ->
        # Non-object JSON (e.g. a plain string) — forward as-is.
        {active, chunk_string}

      {:error, _} ->
        # Not valid JSON — might be a partial SSE line or binary frame.
        # Forward as-is without parsing.
        {active, chunk_string}
    end
  end

  # Handles a parsed JSON chunk from the provider.
  defp handle_parsed_chunk(active, chunk, seq, original_string) do
    active =
      active
      |> remember_provider_response_id(chunk)
      |> Map.put(:seq, seq)
      |> observe_max_tool_calls(chunk)

    case chunk["type"] do
      # ── Text delta ──
      "response.output_text.delta" ->
        delta = chunk["delta"] || ""
        new_active = %{active | text_buffer: active.text_buffer <> delta, seq: seq}
        {new_active, forward_parsed_chunk(active, chunk, original_string)}

      # ── Output item completed ──
      "response.output_item.done" ->
        item = chunk["item"]

        new_items =
          if is_map(item), do: active.accumulated_items ++ [item], else: active.accumulated_items

        new_active =
          Map.put(active, :accumulated_items, new_items)

        {new_active, forward_parsed_chunk(active, chunk, original_string)}

      # ── Function call arguments done ──
      "response.function_call_arguments.done" ->
        # Arguments deltas are not a completed Response item. The completed
        # function_call arrives through output_item.done or terminal response.output.
        {active, forward_parsed_chunk(active, chunk, original_string)}

      # ── Response completed (terminal) ──
      # Rewrite response.id to resp_#{message_id} for stateful runs.
      "response.completed" ->
        response = chunk["response"] || %{}
        output = response["output"] || []

        completed_items = extract_completed_items(output)
        all_items = terminal_items_or_accumulated(active.accumulated_items, completed_items)
        terminal_metadata = terminal_response_metadata(response)

        commit_and_forward_terminal_chunk(
          active,
          chunk,
          all_items,
          nil,
          terminal_metadata,
          seq,
          original_string
        )

      # ── Response failed (terminal) ──
      "response.failed" ->
        handle_terminal_error_chunk(active, chunk, original_string)

      "response.incomplete" ->
        handle_incomplete_chunk(active, chunk, original_string)

      # ── All other event types — forward as-is ──
      _ ->
        {active, forward_parsed_chunk(active, chunk, original_string)}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Typed live event publishing
  # ─────────────────────────────────────────────────────────────────

  defp maybe_publish_typed_events(nil, _old_active, _new_active, _seq), do: :ok

  defp maybe_publish_typed_events(%{message: %{} = message}, old_active, new_active, seq) do
    publish_new_tool_calls(message, old_active, new_active, seq)

    if new_active.text_buffer != old_active.text_buffer do
      delta = text_delta_since(old_active.text_buffer, new_active.text_buffer)

      if delta != "" do
        Events.publish(message, :output_text_delta, %{
          text: delta,
          seq: seq
        })
      end
    end

    :ok
  end

  defp publish_new_tool_calls(message, old_active, new_active, seq) do
    old_items = Map.get(old_active, :accumulated_items, [])
    new_items = Map.get(new_active, :accumulated_items, [])
    old_count = length(old_items)

    new_items
    |> Enum.drop(old_count)
    |> Enum.filter(&tool_activity_item?/1)
    |> Enum.each(fn item ->
      Events.publish(message, :tool_call_started, tool_activity_payload(item, seq))
    end)
  end

  defp tool_activity_payload(item, seq) do
    item
    |> Map.take(["type", "id", "call_id", "name", "status", "output", "action"])
    |> maybe_put_payload("seq", seq)
  end

  defp tool_activity_item?(%{"type" => type}) when is_binary(type) do
    type in ["function_call", "custom_tool_call", "mcp_list_tools"] or
      String.ends_with?(type, "_call")
  end

  defp tool_activity_item?(_item), do: false

  defp maybe_put_payload(payload, _key, nil), do: payload
  defp maybe_put_payload(payload, key, value), do: Map.put(payload, key, value)

  defp text_delta_since(old_text, new_text)
       when is_binary(old_text) and is_binary(new_text) do
    old_size = byte_size(old_text)
    new_size = byte_size(new_text)

    if new_size > old_size do
      binary_part(new_text, old_size, new_size - old_size)
    else
      ""
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Completed item extraction
  # ─────────────────────────────────────────────────────────────────

  # Extracts completed Response items from a terminal response output array.
  defp extract_completed_items(output) when is_list(output) do
    Enum.filter(output, &is_map/1)
  end

  defp extract_completed_items(_), do: []

  defp terminal_items_or_accumulated(accumulated, []), do: accumulated
  defp terminal_items_or_accumulated(_accumulated, terminal_items), do: terminal_items

  defp handle_incomplete_chunk(active, chunk, original_string) do
    response = chunk["response"] || %{}
    output = response["output"] || []
    completed_items = extract_completed_items(output)
    all_items = terminal_items_or_accumulated(active.accumulated_items, completed_items)

    terminal_metadata =
      response
      |> terminal_response_metadata()
      |> maybe_put_metadata("incomplete_details", response["incomplete_details"])

    commit_and_forward_terminal_chunk(
      active,
      chunk,
      all_items,
      nil,
      terminal_metadata,
      nil,
      original_string
    )
  end

  defp handle_terminal_error_chunk(active, chunk, original_string) do
    response = chunk["response"] || %{}
    output = response["output"] || []
    completed_items = extract_completed_items(output)
    all_items = terminal_items_or_accumulated(active.accumulated_items, completed_items)
    error_details = terminal_error_details(chunk)
    terminal_metadata = terminal_response_metadata(response)

    commit_and_forward_terminal_chunk(
      active,
      chunk,
      all_items,
      error_details,
      terminal_metadata,
      nil,
      original_string
    )
  end

  defp observe_max_tool_calls(active, chunk) do
    Map.update(
      active,
      :max_tool_calls,
      nil,
      &MaxToolCalls.observe(&1, chunk)
    )
  end

  defp stop_for_max_tool_calls(state, active, client_chunk) do
    _ = UniversalAIClient.cancel(active.stream)

    response = max_tool_calls_incomplete_response(active)
    terminal_metadata = max_tool_calls_terminal_metadata(active, response)

    active =
      Map.merge(active, %{
        terminal_error: nil,
        terminal_response: response
      })

    case commit_stateful_terminal(
           active.stateful,
           unpersisted_items(active),
           nil,
           terminal_metadata
         ) do
      :ok ->
        active =
          active
          |> Map.put(:terminal_committed, terminal_committed_after_forward?(active))
          |> Map.put(:terminal_received, true)

        next_state =
          state
          |> remember_socket_response(active)
          |> clear_active_stream()

        incomplete_chunk =
          %{
            "type" => "response.incomplete",
            "response" => response
          }
          |> maybe_put_sequence_number(next_sequence_number(active))
          |> Ankole.JSON.encode!()

        {:push, [{:text, client_chunk}, {:text, incomplete_chunk}], next_state}

      {:error, reason} ->
        failed_chunk =
          active
          |> stateful_commit_failed_chunk(reason, next_sequence_number(active))
          |> Ankole.JSON.encode!()

        {:push, [{:text, client_chunk}, {:text, failed_chunk}], clear_active_stream(state)}
    end
  end

  defp max_tool_calls_incomplete_response(active) do
    provider_metadata = %{
      "max_tool_calls" => MaxToolCalls.details(active.max_tool_calls)
    }

    %{
      "id" => cleanup_response_id(active),
      "object" => "response",
      "status" => "incomplete",
      "incomplete_details" => nil,
      "output" => unpersisted_items(active),
      "provider_metadata" => provider_metadata
    }
  end

  defp max_tool_calls_terminal_metadata(active, response) do
    %{
      "provider_metadata" => response["provider_metadata"],
      "response" => %{
        "id" => active.provider_response_id || response["id"],
        "object" => "response",
        "status" => "incomplete"
      }
    }
  end

  defp next_sequence_number(%{seq: seq}) when is_integer(seq), do: seq + 1
  defp next_sequence_number(_active), do: nil

  defp commit_and_forward_terminal_chunk(
         active,
         chunk,
         all_items,
         terminal_error,
         terminal_metadata,
         seq,
         original_string
       ) do
    active =
      Map.merge(active, %{
        accumulated_items: all_items,
        terminal_error: terminal_error,
        terminal_response: terminal_response_for_history(chunk, all_items)
      })

    terminal_committed? = terminal_committed_after_forward?(active)
    terminal_items = unpersisted_items(active)

    case commit_stateful_terminal(
           active.stateful,
           terminal_items,
           terminal_error,
           terminal_metadata
         ) do
      :ok ->
        active =
          active
          |> Map.put(:terminal_committed, terminal_committed?)
          |> Map.put(:terminal_received, true)

        {active, forward_parsed_chunk(active, chunk, original_string)}

      {:error, reason} ->
        active =
          active
          |> Map.put(:terminal_committed, terminal_committed?)
          |> Map.put(:terminal_received, true)

        failed_chunk =
          stateful_commit_failed_chunk(active, reason, seq || chunk["sequence_number"])

        {active, Ankole.JSON.encode!(failed_chunk)}
    end
  end

  defp terminal_committed_after_forward?(%{stateful: nil}), do: false
  defp terminal_committed_after_forward?(%{stateful: _stateful}), do: true

  defp forward_parsed_chunk(active, chunk, original_string) do
    rewritten = maybe_rewrite_response_id(active, chunk)

    if rewritten == chunk do
      original_string
    else
      Ankole.JSON.encode!(rewritten)
    end
  end

  defp maybe_rewrite_response_id(%{stateful: %{message_id: message_id}}, chunk) do
    rewrite_response_id(chunk, "resp_#{message_id}")
  end

  defp maybe_rewrite_response_id(_active, chunk), do: chunk

  defp unpersisted_items(%{accumulated_items: items}) when is_list(items), do: items
  defp unpersisted_items(_active), do: []

  defp terminal_response_metadata(%{} = response) do
    %{}
    |> maybe_put_metadata("usage", response["usage"])
    |> maybe_put_metadata("provider_model", response["model"])
    |> maybe_put_metadata("provider_metadata", provider_response_metadata(response))
    |> maybe_put_metadata("stop_reason", response_stop_reason(response))
    |> maybe_put_metadata("response", response_trace_metadata(response))
  end

  defp terminal_response_metadata(_response), do: %{}

  defp terminal_error_details(%{"type" => type, "response" => %{} = response}) do
    response
    |> Map.take(["error", "incomplete_details", "status", "id"])
    |> Map.put_new("type", type)
    |> maybe_mark_retryable_terminal_error()
  end

  defp terminal_error_details(%{"type" => type}),
    do: %{"type" => type} |> maybe_mark_retryable_terminal_error()

  defp maybe_put_metadata(map, _key, nil), do: map

  defp maybe_put_metadata(map, _key, value)
       when is_map(value) and map_size(value) == 0,
       do: map

  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp provider_response_metadata(response) do
    response
    |> Map.take([
      "id",
      "object",
      "model",
      "status",
      "service_tier",
      "system_fingerprint"
    ])
  end

  defp response_trace_metadata(response) do
    response
    |> Map.take([
      "id",
      "object",
      "created_at",
      "completed_at",
      "status"
    ])
  end

  defp response_stop_reason(%{"stop_reason" => stop_reason}) when is_binary(stop_reason),
    do: stop_reason

  defp response_stop_reason(%{"finish_reason" => finish_reason}) when is_binary(finish_reason),
    do: finish_reason

  defp response_stop_reason(%{"incomplete_details" => %{"reason" => reason}})
       when is_binary(reason),
       do: reason

  defp response_stop_reason(%{"status" => status}) when status in ["failed", "error"], do: "error"

  defp response_stop_reason(%{"output" => output}) when is_list(output) do
    if Enum.any?(output, &function_call_item?/1), do: "tool_use", else: "stop"
  end

  defp response_stop_reason(_response), do: "stop"

  defp function_call_item?(%{"type" => "function_call"}), do: true
  defp function_call_item?(_item), do: false

  # ─────────────────────────────────────────────────────────────────
  # Response ID rewriting
  # ─────────────────────────────────────────────────────────────────

  # Rewrites provider response ids in stateful frames to the Ankole stored id
  # format (plan §1.4).
  defp rewrite_response_id(chunk, new_id) do
    chunk
    |> rewrite_nested_response_id(new_id)
    |> rewrite_top_level_response_id(new_id)
  end

  defp rewrite_nested_response_id(%{"response" => %{}} = chunk, new_id),
    do: put_in(chunk, ["response", "id"], new_id)

  defp rewrite_nested_response_id(chunk, _new_id), do: chunk

  defp rewrite_top_level_response_id(%{"response_id" => response_id} = chunk, new_id)
       when is_binary(response_id),
       do: Map.put(chunk, "response_id", new_id)

  defp rewrite_top_level_response_id(chunk, _new_id), do: chunk

  # ─────────────────────────────────────────────────────────────────
  # Stateful run lifecycle
  # ─────────────────────────────────────────────────────────────────

  defp open_active_stream(state, request) do
    case safe_open_websocket_stream(state.subject_uid, request) do
      {:ok, stream, meta} ->
        case UniversalAIClient.read(stream, 1) do
          :ok ->
            schedule_response_heartbeat(stream.ref, stateful_context_from_meta(meta))

            {:ok,
             %{
               ref: stream.ref,
               stream: stream,
               stateful: stateful_context_from_meta(meta),
               # Completed Response items held in memory until terminal commit.
               accumulated_items: [],
               request_input: Map.get(request, "input"),
               # Accumulated assistant text (for typed live chunk events).
               text_buffer: "",
               provider_response_id: nil,
               terminal_response: nil,
               seq: 0,
               terminal_error: nil,
               terminal_committed: false,
               terminal_received: false,
               max_tool_calls:
                 MaxToolCalls.new(
                   Map.get(request, "max_tool_calls"),
                   stream_api_resolver(meta)
                 )
             }}

          {:error, reason} ->
            _ = UniversalAIClient.cancel(stream)

            commit_stateful_error(
              stateful_context_from_meta(meta),
              "provider_stream_initial_read_failed: #{inspect(reason)}",
              [],
              code: "provider_stream_error",
              retryable: true
            )

            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stateful_context_from_meta(%{stateful: stateful_context}), do: stateful_context
  defp stateful_context_from_meta(_meta), do: nil

  defp stream_api_resolver(meta) when is_map(meta),
    do: Map.get(meta, "api_resolver") || Map.get(meta, :api_resolver)

  defp stream_api_resolver(_meta), do: nil

  defp safe_open_websocket_stream(subject_uid, request) do
    AIGateway.open_websocket_stream(subject_uid, request)
  rescue
    error ->
      {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # ─────────────────────────────────────────────────────────────────
  # Error / cleanup helpers
  # ─────────────────────────────────────────────────────────────────

  defp commit_stateful_terminal(nil, _items, _terminal_error, _terminal_metadata), do: :ok

  defp commit_stateful_terminal(stateful, items, nil, terminal_metadata) do
    case StatefulResponses.commit_complete(stateful.message_id, items, terminal_metadata) do
      {:ok, %{} = _message} ->
        :ok

      {:ok, :already_terminal} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "ai_gateway.socket.complete_commit_failed",
          "AIGateway response complete commit failed",
          %{
            message_id: stateful.message_id,
            reason: inspect(reason)
          }
        )

        commit_stateful_terminal_commit_failure(stateful, items, reason)
        {:error, reason}
    end
  end

  defp commit_stateful_terminal(stateful, items, error_details, terminal_metadata) do
    opts = [metadata: terminal_metadata]

    case StatefulResponses.commit_error(stateful.message_id, items, error_details, opts) do
      {:ok, %{} = _message} ->
        :ok

      {:ok, :already_terminal} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "ai_gateway.socket.error_commit_failed",
          "AIGateway response error commit failed",
          %{
            message_id: stateful.message_id,
            reason: inspect(reason)
          }
        )

        {:error, reason}
    end
  end

  defp commit_stateful_terminal_commit_failure(stateful, items, reason) do
    StatefulResponses.commit_error(
      stateful.message_id,
      items,
      %{
        "reason" => "stateful_terminal_commit_failed",
        "stage" => "terminal_commit",
        "details" => inspect(reason)
      }
    )
  end

  # Commits a stateful generating row as error if one exists.
  defp commit_stateful_error(nil, _reason, _partial_content, _opts), do: :ok

  defp commit_stateful_error(message_id, reason, partial_content, opts)
       when is_binary(message_id) do
    retryable? = Keyword.get(opts, :retryable, false)

    error_details =
      %{
        "code" => Keyword.get(opts, :code, "socket_cleanup_error"),
        "reason" => reason,
        "stage" => "socket_cleanup"
      }
      |> maybe_put_retryable(retryable?)

    StatefulResponses.commit_error(message_id, partial_content, error_details)
  end

  defp commit_stateful_error(%{message_id: message_id}, reason, partial_content, opts) do
    commit_stateful_error(message_id, reason, partial_content, opts)
  end

  defp maybe_put_retryable(error_details, true), do: Map.put(error_details, "retryable", true)
  defp maybe_put_retryable(error_details, _retryable?), do: error_details

  defp fail_active_stream(state, active, reason, opts) do
    if Map.get(active, :terminal_committed, false) do
      {:ok, clear_active_stream(state)}
    else
      commit_stateful_error(
        Map.get(active, :stateful),
        reason,
        unpersisted_items(active),
        opts
      )

      state =
        state
        |> evict_socket_response_history(Map.get(active, :socket_previous_response_id))
        |> clear_active_stream()

      {:push, Ankole.JSON.encode!(stateful_cleanup_failed_chunk(active, reason, opts)), state}
    end
  end

  defp stateful_cleanup_failed_chunk(active, reason, opts) do
    response_id = cleanup_response_id(active)

    error =
      %{
        "code" => Keyword.get(opts, :code, "provider_stream_error"),
        "message" => cleanup_error_message(Keyword.get(opts, :code, "provider_stream_error")),
        "details" => reason
      }
      |> maybe_put_retryable(Keyword.get(opts, :retryable, false))

    %{
      "type" => "response.failed",
      "response" => %{
        "id" => response_id,
        "object" => "response",
        "status" => "failed",
        "error" => error,
        "output" => []
      }
    }
  end

  defp remember_provider_response_id(active, %{"response" => %{"id" => response_id}})
       when is_binary(response_id) do
    Map.put(active, :provider_response_id, Map.get(active, :provider_response_id) || response_id)
  end

  defp remember_provider_response_id(active, %{"response_id" => response_id})
       when is_binary(response_id) do
    Map.put(active, :provider_response_id, Map.get(active, :provider_response_id) || response_id)
  end

  defp remember_provider_response_id(active, _chunk), do: active

  defp cleanup_response_id(%{stateful: %{message_id: message_id}}) when is_binary(message_id),
    do: "resp_#{message_id}"

  defp cleanup_response_id(%{provider_response_id: response_id}) when is_binary(response_id),
    do: response_id

  defp cleanup_response_id(_active), do: nil

  defp cleanup_error_message("provider_stream_closed_without_terminal"),
    do: "AIGateway provider stream closed before a terminal response."

  defp cleanup_error_message("provider_stream_aborted"),
    do: "AIGateway provider stream was aborted before a terminal response."

  defp cleanup_error_message(_code),
    do: "AIGateway provider stream failed before a terminal response."

  defp stateful_commit_failed_chunk(active, reason, sequence_number) do
    response_id =
      case active.stateful do
        %{message_id: message_id} -> "resp_#{message_id}"
        _ -> nil
      end

    response =
      %{
        "id" => response_id,
        "object" => "response",
        "status" => "failed",
        "error" => %{
          "code" => "stateful_commit_failed",
          "message" =>
            "AIGateway failed to commit the stateful response before forwarding the terminal frame.",
          "details" => inspect(reason)
        },
        "output" => []
      }

    %{
      "type" => "response.failed",
      "response" => response
    }
    |> maybe_put_sequence_number(sequence_number)
  end

  defp maybe_put_sequence_number(event, nil), do: event

  defp maybe_put_sequence_number(event, sequence_number),
    do: Map.put(event, "sequence_number", sequence_number)

  # ─────────────────────────────────────────────────────────────────
  # Validation helpers
  # ─────────────────────────────────────────────────────────────────

  defp ensure_no_active_stream(%{active_stream: _stream} = state) do
    {:error,
     %{
       event:
         error_event(
           409,
           "response_in_progress",
           "AIGateway Responses WebSocket already has an active response."
         ),
       state: state
     }}
  end

  defp ensure_no_active_stream(_state), do: :ok

  defp decode_socket_event(payload, state) do
    with {:ok, event} <- Ankole.JSON.decode(payload),
         {:ok, event} <- ensure_object(event),
         :ok <- ensure_socket_event_type(event) do
      {:ok, event}
    else
      {:error, %{event: _event} = error} ->
        {:error, error}

      {:error, code, message, param} ->
        {:error, %{event: error_event(400, code, message, param), state: state}}

      {:error, _reason} ->
        {:error,
         %{
           event:
             error_event(400, "invalid_request_error", "WebSocket message must be valid JSON."),
           state: state
         }}
    end
  end

  defp ensure_object(event) when is_map(event), do: {:ok, event}

  defp ensure_object(_event),
    do: {:error, "invalid_request_error", "WebSocket message must be a JSON object.", nil}

  defp ensure_socket_event_type(%{"type" => "response.create"}), do: :ok
  defp ensure_socket_event_type(%{"type" => "response.tool_results.record"}), do: :ok

  defp ensure_socket_event_type(_event),
    do:
      {:error, "invalid_request_error",
       "WebSocket message type must be response.create or response.tool_results.record.", "type"}

  # Only strip the socket event type here. store/previous_response_id/
  # conversation/metadata are preserved for the stateful path and stripped later
  # at the provider request boundary.
  defp prepare_request(event) do
    Map.delete(event, "type")
  end

  defp clear_active_stream(state), do: Map.delete(state, :active_stream)

  defp prepare_response_create_request(state, %{"previous_response_id" => response_id} = request)
       when is_binary(response_id) do
    if request["store"] == true do
      {:ok, request, %{}}
    else
      prepare_socket_local_previous_response(state, response_id, request)
    end
  end

  defp prepare_response_create_request(_state, request), do: {:ok, request, %{}}

  defp prepare_socket_local_previous_response(state, response_id, request) do
    case get_in(state, [:response_history, response_id]) do
      %{items: history_items} when is_list(history_items) ->
        input = history_items ++ response_input_items(Map.get(request, "input"))

        request =
          request
          |> Map.put("input", input)
          |> Map.delete("previous_response_id")
          |> Map.put("store", false)
          |> Map.delete("conversation")

        {:ok, request, %{socket_previous_response_id: response_id}}

      _missing ->
        {:error, :previous_response_not_found}
    end
  end

  defp schedule_response_heartbeat(ref, %{message_id: _message_id}),
    do: Process.send_after(self(), {:ai_gateway_response_heartbeat, ref}, @response_heartbeat_ms)

  defp schedule_response_heartbeat(_ref, nil), do: :ok

  defp schedule_response_heartbeat(ref),
    do: Process.send_after(self(), {:ai_gateway_response_heartbeat, ref}, @response_heartbeat_ms)

  defp remember_socket_response(
         state,
         %{
           stateful: nil,
           socket_previous_response_id: response_id,
           terminal_error: terminal_error
         }
       )
       when is_binary(response_id) and not is_nil(terminal_error) do
    evict_socket_response_history(state, response_id)
  end

  defp remember_socket_response(
         state,
         %{stateful: nil, terminal_response: %{"id" => response_id}} = active
       )
       when is_binary(response_id) do
    entry = %{
      response: active.terminal_response,
      items: response_input_items(Map.get(active, :request_input)) ++ unpersisted_items(active)
    }

    put_socket_response_history(state, response_id, entry)
  end

  defp remember_socket_response(state, _active), do: state

  defp evict_socket_response_history(state, response_id) when is_binary(response_id) do
    state
    |> Map.update(:response_history, %{}, &Map.delete(&1, response_id))
    |> Map.update(:response_history_order, [], &Enum.reject(&1, fn id -> id == response_id end))
  end

  defp evict_socket_response_history(state, _response_id), do: state

  defp put_socket_response_history(state, response_id, entry) do
    order =
      [
        response_id
        | Enum.reject(Map.get(state, :response_history_order, []), &(&1 == response_id))
      ]

    {kept, _dropped} = Enum.split(order, @socket_response_history_limit)

    history =
      state
      |> Map.get(:response_history, %{})
      |> Map.put(response_id, entry)
      |> Map.take(kept)

    state
    |> Map.put(:response_history, history)
    |> Map.put(:response_history_order, kept)
  end

  defp response_input_items(input) when is_list(input), do: Enum.filter(input, &is_map/1)

  defp response_input_items(input) when is_binary(input) do
    [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => input}]
      }
    ]
  end

  defp response_input_items(_input), do: []

  defp terminal_response_for_history(%{"response" => %{} = response}, all_items) do
    Map.put(response, "output", all_items)
  end

  defp terminal_response_for_history(_chunk, all_items), do: %{"id" => nil, "output" => all_items}

  defp error_event(status, code, message, param \\ nil, details \\ nil) do
    error =
      %{
        "type" => "invalid_request_error",
        "code" => code,
        "message" => message,
        "param" => param
      }
      |> maybe_put_error_details(details)

    %{
      "type" => "error",
      "sequence_number" => 0,
      "status" => status,
      "error" => error
    }
  end

  defp maybe_put_error_details(error, nil), do: error
  defp maybe_put_error_details(error, details), do: Map.put(error, "details_json", details)

  defp tool_results_recorded_event(response_body) do
    %{
      "type" => "response.tool_results.recorded",
      "sequence_number" => 0,
      "response_id" => response_body["id"],
      "response" => response_body
    }
  end

  defp upstream_response_failed_event(status, body) do
    error_event(
      public_upstream_status(status),
      "upstream_response_failed",
      upstream_error_message(status, body),
      nil,
      %{
        "stage" => "socket_open",
        "upstream_status" => status,
        "upstream_body" => body,
        "retryable" => retryable_upstream_status?(status)
      }
    )
  end

  defp public_upstream_status(status) when is_integer(status) and status >= 400 and status <= 599,
    do: status

  defp public_upstream_status(_status), do: 502

  defp upstream_error_message(_status, %{"error" => %{"message" => message}})
       when is_binary(message),
       do: message

  defp upstream_error_message(_status, %{"message" => message}) when is_binary(message),
    do: message

  defp upstream_error_message(status, _body), do: "Provider request failed with status #{status}."

  defp retryable_upstream_status?(status) when status in [408, 409, 425, 429], do: true
  defp retryable_upstream_status?(status) when is_integer(status) and status >= 500, do: true
  defp retryable_upstream_status?(_status), do: false

  defp maybe_mark_retryable_terminal_error(%{} = details) do
    if retryable_terminal_error?(details), do: Map.put(details, "retryable", true), else: details
  end

  defp retryable_terminal_error?(%{"retryable" => true}), do: true

  defp retryable_terminal_error?(%{} = details) do
    status =
      integer_value(details["status"]) ||
        integer_value(get_in(details, ["error", "status"]))

    code =
      (string_value(get_in(details, ["error", "code"])) || string_value(details["code"]) || "")
      |> String.downcase()

    message =
      (string_value(get_in(details, ["error", "message"])) || string_value(details["message"]) ||
         "")
      |> String.downcase()

    retryable_upstream_status?(status) or
      String.contains?(code, "429") or
      String.contains?(code, "rate_limit") or
      String.contains?(message, "rate limit") or
      String.contains?(message, "too many requests") or
      Regex.match?(~r/(^|\D)429(\D|$)/, message)
  end

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil

  defp universal_ai_request_failed_event(details) do
    status = upstream_status_from_universal_error(details)

    error_event(
      public_upstream_status(status),
      universal_socket_open_code(status),
      universal_socket_open_message(status, details),
      nil,
      %{
        "stage" => "socket_open",
        "upstream_status" => status,
        "upstream_body" => details,
        "retryable" => retryable_upstream_status?(status)
      }
    )
  end

  defp upstream_status_from_universal_error(%{"status" => status}) when is_integer(status),
    do: status

  defp upstream_status_from_universal_error(%{"message" => message}) when is_binary(message) do
    case Regex.run(~r/HTTP error:\s*(\d{3})/, message) do
      [_match, status] -> String.to_integer(status)
      _no_match -> nil
    end
  end

  defp upstream_status_from_universal_error(_details), do: nil

  defp universal_socket_open_code(status) when is_integer(status), do: "upstream_response_failed"
  defp universal_socket_open_code(_status), do: "ai_gateway_request_failed"

  defp universal_socket_open_message(_status, %{"message" => message}) when is_binary(message),
    do: message

  defp universal_socket_open_message(status, _details) when is_integer(status),
    do: upstream_error_message(status, %{})

  defp universal_socket_open_message(_status, _details), do: "AIGateway request failed."
end
