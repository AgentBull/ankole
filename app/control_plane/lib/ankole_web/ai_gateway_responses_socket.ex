defmodule AnkoleWeb.AIGatewayResponsesSocket do
  @moduledoc """
  OpenResponses WebSocket transport for AIGateway.

  Supports both stateless and stateful (`store=true`) response.create runs.
  For stateful runs, a generating `ai_gateway_messages` row is created before
  the provider call, and committed (complete/error) when the stream finishes.

  Provider stream frames are parsed into typed semantic events that feed three
  consumers simultaneously:
    1. **Client forwarding** — raw JSON text pushed to the WebSocket client.
    2. **Durable content accumulation** — stable Response items collected for
       `commit_complete` at terminal state.
    3. **Typed live chunk publishing** — semantic events (text deltas, function
       calls) published via PubSub for SignalsGateway preview/finalize.

  Response ID rewriting: terminal frames have their `response.id` rewritten
  from the provider's raw id to `resp_{message_id}` before
  forwarding to the client (plan §1.4 — provider ids must not become stored ids).
  """

  @behaviour WebSock

  alias Ankole.AIGateway
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Kernel.UniversalAIClient

  require Logger

  @http_only_websocket_fields ~w(stream stream_options background)

  # ─────────────────────────────────────────────────────────────────
  # Connection lifecycle
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def init(%{subject_uid: subject_uid, subject_type: subject_type}) do
    {:ok, %{subject_uid: subject_uid, subject_type: subject_type}}
  end

  def init(%{agent_uid: agent_uid}) do
    init(%{subject_uid: agent_uid, subject_type: "agent"})
  end

  # ─────────────────────────────────────────────────────────────────
  # Incoming: response.create
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def handle_in({payload, [opcode: :text]}, state) do
    with :ok <- ensure_no_active_stream(state),
         {:ok, event} <- decode_create_event(payload, state),
         request <- prepare_request(event),
         {:ok, stateful_context} <- maybe_start_stateful_run(state, request) do
      case open_active_stream(state, request, stateful_context) do
        {:ok, active_stream} ->
          {:ok, Map.put(state, :active_stream, active_stream)}

        {:error, reason} ->
          event = error_event(422, "ai_gateway_request_failed", inspect(reason))
          {:push, {:text, Ankole.JSON.encode!(event)}, state}
      end
    else
      # Error from maybe_start_stateful_run: if a generating row was already
      # created but the provider call failed, commit it as error.
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

      {:error, :invalid_conversation} ->
        event =
          error_event(
            403,
            "invalid_stateful_conversation",
            "conversation does not reference an active conversation owned by this agent."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :missing_stateful_claims} ->
        event =
          error_event(
            403,
            "stateful_claims_required",
            "store=true requires valid conversation and actor_event_id claims."
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

      {:error, reason} ->
        event = error_event(422, "ai_gateway_request_failed", inspect(reason))
        {:push, {:text, Ankole.JSON.encode!(event)}, state}
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

  # ─────────────────────────────────────────────────────────────────
  # Provider stream events
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def handle_info(
        {:universal_ai_client, ref, :chunk, seq, :websocket_text, chunk},
        %{active_stream: %{ref: ref, stream: stream, stateful: stateful} = active} = state
      ) do
    # Parse the provider frame to extract stable items + typed events.
    # The raw chunk is still forwarded to the client unmodified (except for
    # response ID rewriting on terminal frames, handled in :done/:error).
    {new_active, client_chunk} = process_provider_chunk(active, chunk, seq)

    # Publish typed live events for stateful runs (SignalsGateway subscribes).
    maybe_publish_typed_events(stateful, active, new_active, seq)

    case UniversalAIClient.read(stream, 1) do
      :ok ->
        {:push, {:text, client_chunk}, Map.put(state, :active_stream, new_active)}

      {:error, _reason} ->
        {:push, {:text, client_chunk}, clear_active_stream_with_error(state, stateful)}
    end
  end

  def handle_info(
        {:universal_ai_client, ref, :chunk, _seq, kind, _chunk},
        %{active_stream: %{ref: ref, stream: stream, stateful: stateful}} = state
      ) do
    _ = UniversalAIClient.cancel(stream)
    commit_stateful_error(stateful, "unexpected_chunk_kind: #{inspect(kind)}")

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
        %{active_stream: %{ref: ref, stateful: stateful, accumulated_items: items} = active} =
          state
      ) do
    commit_stateful_terminal(stateful, items, Map.get(active, :terminal_error))

    {:ok, clear_active_stream(state)}
  end

  # Stream errored.
  def handle_info(
        {:universal_ai_client, ref, :error, error},
        %{active_stream: %{ref: ref, stateful: stateful}} = state
      ) do
    commit_stateful_error(stateful, "provider_stream_error: #{inspect(error)}")
    {:ok, clear_active_stream(state)}
  end

  # Stream aborted (e.g. client disconnect, timeout).
  def handle_info(
        {:universal_ai_client, ref, :aborted},
        %{active_stream: %{ref: ref, stateful: stateful}} = state
      ) do
    commit_stateful_error(stateful, "stream_aborted")
    {:ok, clear_active_stream(state)}
  end

  def handle_info({:universal_ai_client, _ref, _kind, _payload}, state), do: {:ok, state}
  def handle_info({:universal_ai_client, _ref, _kind}, state), do: {:ok, state}

  def handle_info({:universal_ai_client, _ref, _kind, _seq, _chunk_kind, _binary}, state),
    do: {:ok, state}

  def handle_info(_message, state), do: {:ok, state}

  # ─────────────────────────────────────────────────────────────────
  # Termination — clean up any leaking generating row
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def terminate(_reason, %{active_stream: %{stream: stream, stateful: stateful}}) do
    _ = UniversalAIClient.cancel(stream)
    commit_stateful_error(stateful, "socket_terminated")
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ─────────────────────────────────────────────────────────────────
  # Provider chunk processing
  # ─────────────────────────────────────────────────────────────────

  # Parses a provider WebSocket text chunk into structured events.
  # Extracts stable Response items (for durable accumulation) and typed
  # semantic events (for live PubSub publishing).
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
    case chunk["type"] do
      # ── Text delta ──
      "response.output_text.delta" ->
        delta = chunk["delta"] || ""
        new_active = %{active | text_buffer: active.text_buffer <> delta, seq: seq}
        {new_active, original_string}

      # ── Output item completed (stable item boundary) ──
      "response.output_item.done" ->
        item = chunk["item"]

        new_items =
          if is_map(item), do: active.accumulated_items ++ [item], else: active.accumulated_items

        new_active = %{active | accumulated_items: new_items}
        {new_active, original_string}

      # ── Function call arguments done (stable item boundary) ──
      "response.function_call_arguments.done" ->
        # Arguments deltas are not a stable Response item. The completed
        # function_call arrives through output_item.done or terminal response.output.
        {active, original_string}

      # ── Response completed (terminal) ──
      # Rewrite response.id to resp_#{message_id} for stateful runs.
      "response.completed" ->
        response = chunk["response"] || %{}
        output = response["output"] || []

        stable_items = extract_stable_items(output)
        all_items = terminal_items_or_accumulated(active.accumulated_items, stable_items)

        # Rewrite the response ID for the client.
        rewritten_chunk =
          if active.stateful do
            rewrite_response_id(chunk, "resp_#{active.stateful.message_id}")
          else
            chunk
          end

        new_active = %{active | accumulated_items: all_items, terminal_error: nil}
        rewritten_string = Ankole.JSON.encode!(rewritten_chunk)
        {new_active, rewritten_string}

      # ── Response failed (terminal) ──
      "response.failed" ->
        handle_terminal_error_chunk(active, chunk, original_string)

      "response.incomplete" ->
        handle_terminal_error_chunk(active, chunk, original_string)

      # ── All other event types — forward as-is ──
      _ ->
        {active, original_string}
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Typed live event publishing
  # ─────────────────────────────────────────────────────────────────

  defp maybe_publish_typed_events(nil, _old_active, _new_active, _seq), do: :ok

  defp maybe_publish_typed_events(%{message_id: _message_id}, old_active, new_active, seq) do
    actor_event_id = get_in(new_active, [:stateful, :actor_event_id])

    if actor_event_id && new_active.text_buffer != old_active.text_buffer do
      # Compute the delta since last publish.
      delta = String.slice(new_active.text_buffer, String.length(old_active.text_buffer)..-1//1)

      if delta != "" do
        StatefulResponses.publish_typed_event(actor_event_id, :output_text_delta, %{
          text: delta,
          seq: seq
        })
      end
    end

    :ok
  end

  # ─────────────────────────────────────────────────────────────────
  # Stable item extraction
  # ─────────────────────────────────────────────────────────────────

  # Extracts stable Response items from a terminal response output array.
  defp extract_stable_items(output) when is_list(output) do
    Enum.flat_map(output, fn item ->
      case item["type"] do
        "message" -> [item]
        "function_call" -> [item]
        "reasoning" -> [item]
        _ -> []
      end
    end)
  end

  defp extract_stable_items(_), do: []

  defp terminal_items_or_accumulated(accumulated, []), do: accumulated
  defp terminal_items_or_accumulated(_accumulated, terminal_items), do: terminal_items

  defp handle_terminal_error_chunk(active, chunk, original_string) do
    response = chunk["response"] || %{}
    output = response["output"] || []
    stable_items = extract_stable_items(output)
    all_items = terminal_items_or_accumulated(active.accumulated_items, stable_items)
    error_details = terminal_error_details(chunk)

    active = %{active | accumulated_items: all_items, terminal_error: error_details}

    if active.stateful do
      rewritten = rewrite_response_id(chunk, "resp_#{active.stateful.message_id}")
      {active, Ankole.JSON.encode!(rewritten)}
    else
      {active, original_string}
    end
  end

  defp terminal_error_details(%{"type" => type, "response" => %{} = response}) do
    response
    |> Map.take(["error", "incomplete_details", "status", "id"])
    |> Map.put_new("type", type)
  end

  defp terminal_error_details(%{"type" => type}), do: %{"type" => type}

  # ─────────────────────────────────────────────────────────────────
  # Response ID rewriting
  # ─────────────────────────────────────────────────────────────────

  # Rewrites response.id in a response.completed/failed frame to the
  # Ankole stored id format (plan §1.4).
  defp rewrite_response_id(chunk, new_id) do
    case chunk["response"] do
      %{} ->
        put_in(chunk, ["response", "id"], new_id)

      _ ->
        chunk
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Stateful run lifecycle
  # ─────────────────────────────────────────────────────────────────

  # When store=true is present and we have actor-event claims, start a stateful
  # response run by creating a generating ai_gateway_messages row.
  # Returns {:ok, nil} for stateless runs (no store).
  defp maybe_start_stateful_run(state, request) do
    store? = request["store"] == true

    cond do
      not store? and websocket_continuation_requested?(request) ->
        {:error, :stateful_store_required}

      not store? ->
        {:ok, nil}

      true ->
        conversation_id = request["conversation"]
        actor_event_id = get_in(request, ["metadata", "actor_event_id"])

        # 0b: Reject store=true without valid claims (plan §3.1/§3.2).
        # No more silent pass-through for missing conversation/event id.
        if is_nil(conversation_id) or is_nil(actor_event_id) do
          {:error, :missing_stateful_claims}
        else
          conv_id = decode_conv_id(conversation_id)

          case StatefulResponses.start_response_run(%{
                 agent_uid: state.subject_uid,
                 conversation_id: conv_id,
                 actor_event_id: actor_event_id,
                 previous_response_id: request["previous_response_id"],
                 request_items: Map.get(request, "input", [])
               }) do
            {:ok, message} ->
              {:ok, %{message_id: message.id, actor_event_id: actor_event_id}}

            {:error, :invalid_anchor} ->
              {:error, :invalid_anchor}

            {:error, _changeset} = error ->
              error
          end
        end
    end
  end

  defp websocket_continuation_requested?(request) do
    Map.has_key?(request, "previous_response_id") or Map.has_key?(request, "conversation")
  end

  defp decode_conv_id("conv_" <> uuid), do: uuid
  defp decode_conv_id(uuid), do: uuid

  defp open_active_stream(state, request, stateful_context) do
    case safe_open_websocket_stream(state.subject_uid, request) do
      {:ok, stream, _meta} ->
        case UniversalAIClient.read(stream, 1) do
          :ok ->
            {:ok,
             %{
               ref: stream.ref,
               stream: stream,
               stateful: stateful_context,
               # Accumulator for stable Response items (for durable commit).
               accumulated_items: [],
               # Accumulated assistant text (for typed live chunk events).
               text_buffer: "",
               seq: 0,
               terminal_error: nil
             }}

          {:error, reason} ->
            _ = UniversalAIClient.cancel(stream)

            commit_stateful_error(
              stateful_context,
              "provider_stream_initial_read_failed: #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        commit_stateful_error(stateful_context, "provider_call_failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

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

  defp commit_stateful_terminal(nil, _items, _terminal_error), do: :ok

  defp commit_stateful_terminal(stateful, items, nil) do
    case StatefulResponses.commit_complete(stateful.message_id, items, %{}) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("AIGateway response complete commit failed: #{inspect(reason)}")
        :ok
    end
  end

  defp commit_stateful_terminal(stateful, items, error_details) do
    case StatefulResponses.commit_error(stateful.message_id, items, error_details) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.warning("AIGateway response error commit failed: #{inspect(reason)}")
        :ok
    end
  end

  # Commits a stateful generating row as error if one exists.
  defp commit_stateful_error(nil, _reason), do: :ok

  defp commit_stateful_error(message_id, reason) when is_binary(message_id) do
    StatefulResponses.commit_error(message_id, [], %{
      "reason" => reason,
      "stage" => "socket_cleanup"
    })
  end

  defp commit_stateful_error(%{message_id: message_id}, reason) do
    commit_stateful_error(message_id, reason)
  end

  defp commit_stateful_error(%{"message_id" => message_id}, reason) do
    commit_stateful_error(message_id, reason)
  end

  # Clears active stream with error cleanup.
  defp clear_active_stream_with_error(state, stateful) do
    commit_stateful_error(stateful, "stream_read_failed")
    clear_active_stream(state)
  end

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

  defp decode_create_event(payload, state) do
    with {:ok, event} <- Ankole.JSON.decode(payload),
         {:ok, event} <- ensure_object(event),
         :ok <- ensure_create_type(event),
         :ok <- reject_http_only_fields(event) do
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

  defp ensure_create_type(%{"type" => "response.create"}), do: :ok

  defp ensure_create_type(_event),
    do:
      {:error, "invalid_request_error", "WebSocket message type must be response.create.", "type"}

  defp reject_http_only_fields(event) do
    case Enum.find(@http_only_websocket_fields, &Map.has_key?(event, &1)) do
      nil ->
        :ok

      field ->
        {:error, "invalid_request_error",
         "#{field} must not be sent in WebSocket response.create messages.", field}
    end
  end

  # Phase 1: only strip "type" from the event. store/previous_response_id/
  # conversation/metadata are preserved for the stateful path (they are
  # stripped later in the provider call boundary, see history expansion step 1).
  defp prepare_request(event) do
    Map.delete(event, "type")
  end

  defp clear_active_stream(state), do: Map.delete(state, :active_stream)

  defp error_event(status, code, message, param \\ nil) do
    %{
      "type" => "error",
      "sequence_number" => 0,
      "status" => status,
      "error" => %{
        "type" => "invalid_request_error",
        "code" => code,
        "message" => message,
        "param" => param
      }
    }
  end
end
