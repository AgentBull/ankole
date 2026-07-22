defmodule AnkoleWeb.AIGatewayResponsesSocket do
  @moduledoc """
  OpenResponses WebSocket transport for AIGateway.

  This module owns only WebSocket commands, JSON framing, and connection-local
  stateless continuation history. `Ankole.AIGateway.ResponseStream` owns native
  demand, persistence, stateful commits, public projection, and telemetry.
  """

  @behaviour WebSock

  alias Ankole.AIGateway
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.SignalsGateway.AIGatewayLink

  @socket_response_history_limit 32

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
            "This conversation already has an active stateful run."
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

      {:error, {:tool_results_quarantined, %{} = details}} ->
        event =
          error_event(
            409,
            "tool_results_quarantined",
            "Tool results did not match executable calls on the anchor and were excluded from canonical history.",
            "input",
            details
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, %OpenAIError{} = error} ->
        event = openai_error_event(error)
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

    case AIGatewayLink.record_tool_results(state.subject_uid, request) do
      {:ok, %{body: body}} ->
        event = tool_results_recorded_event(body)
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, _reason} = error ->
        error
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # AIGateway response stream
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def handle_info(
        {:ai_gateway_response_stream, ref, :events, events, :continue},
        %{active_stream: %{ref: ref, stream: stream}} = state
      ) do
    chunks = Enum.map(events, &Ankole.JSON.encode!/1)

    case AIGateway.read_response_stream(stream, 1) do
      :ok ->
        push_text_chunks(chunks, state)

      {:error, reason} ->
        event =
          error_event(
            502,
            "provider_stream_error",
            "AIGateway response stream could not continue.",
            nil,
            %{"reason" => inspect(reason)}
          )

        push_text_chunks(chunks ++ [Ankole.JSON.encode!(event)], clear_active_stream(state))
    end
  end

  def handle_info(
        {:ai_gateway_response_stream, ref, :events, events, {:terminal, outcome}},
        %{active_stream: %{ref: ref} = active} = state
      ) do
    state =
      state
      |> remember_socket_response(active, outcome)
      |> clear_active_stream()

    events
    |> Enum.map(&Ankole.JSON.encode!/1)
    |> push_text_chunks(state)
  end

  def handle_info({:ai_gateway_response_stream, _ref, :events, _events, _status}, state),
    do: {:ok, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{active_stream: %{stream: stream}}) do
    _ = AIGateway.cancel_response_stream(stream, "socket_terminated")
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_active_stream(state, request) do
    case safe_open_websocket_stream(state.subject_uid, request) do
      {:ok, stream, _meta} ->
        case AIGateway.read_response_stream(stream, 1) do
          :ok ->
            {:ok,
             %{
               ref: stream.ref,
               stream: stream,
               request_input: Map.get(request, "input")
             }}

          {:error, reason} ->
            _ = AIGateway.cancel_response_stream(stream, "provider_stream_initial_read_failed")
            {:error, reason}
        end

      {:error, reason} ->
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

  defp push_text_chunks([], state), do: {:ok, state}
  defp push_text_chunks([chunk], state), do: {:push, {:text, chunk}, state}

  defp push_text_chunks(chunks, state),
    do: {:push, Enum.map(chunks, &{:text, &1}), state}

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

  defp remember_socket_response(
         state,
         %{socket_previous_response_id: response_id},
         %{stateful?: false, terminal_error: terminal_error}
       )
       when is_binary(response_id) and not is_nil(terminal_error) do
    evict_socket_response_history(state, response_id)
  end

  defp remember_socket_response(
         state,
         active,
         %{
           stateful?: false,
           terminal_response: %{"id" => response_id} = response,
           public_items: public_items
         }
       )
       when is_binary(response_id) and is_list(public_items) do
    entry = %{
      response: response,
      items: response_input_items(Map.get(active, :request_input)) ++ public_items
    }

    put_socket_response_history(state, response_id, entry)
  end

  defp remember_socket_response(state, _active, _outcome), do: state

  defp evict_socket_response_history(state, response_id) when is_binary(response_id) do
    state
    |> Map.update(:response_history, %{}, &Map.delete(&1, response_id))
    |> Map.update(:response_history_order, [], &Enum.reject(&1, fn id -> id == response_id end))
  end

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

  defp openai_error_event(%OpenAIError{} = error) do
    %{
      "type" => "error",
      "sequence_number" => 0,
      "code" => error.code,
      "message" => error.message,
      "param" => error.param
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
