defmodule AnkoleWeb.AIGatewayResponsesSocket do
  @moduledoc """
  OpenResponses WebSocket transport for AIGateway.

  This module owns only WebSocket commands, JSON framing, and connection-local
  stateless continuation history. `Ankole.AIGateway.ResponseStream` owns native
  demand, persistence, stateful commits, public projection, and telemetry.
  """

  @behaviour WebSock

  alias Ankole.AIGateway
  alias Ankole.AIGateway.CodexModelBinding
  alias Ankole.AIGateway.Compaction
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Logging
  alias Ankole.OIDC.Grant
  alias Ankole.SignalsGateway.AIGatewayLink

  @socket_response_history_limit 32

  # Connection lifecycle

  @impl WebSock
  def init(%{subject_uid: _subject_uid, subject_type: _subject_type} = state), do: {:ok, state}

  # Incoming: response.create

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

      # The Responses spec names one flat `error` event for a rejected request
      # body; every other failure uses the wrapped frame that carries a status.
      {:error, %OpenAIError{} = error} ->
        {:push, {:text, Ankole.JSON.encode!(openai_error_event(error))}, state}

      {:error, reason} ->
        {:push, {:text, Ankole.JSON.encode!(error_frame(reason, stage: "socket_open"))}, state}

      other ->
        other
    end
  end

  def handle_in({_payload, [opcode: :binary]}, state) do
    event =
      request_error_frame(
        "invalid_request_error",
        "AIGateway Responses WebSocket accepts only JSON text frames."
      )

    {:push, {:text, Ankole.JSON.encode!(event)}, state}
  end

  defp handle_socket_event(
         %{"type" => "response.create", "generate" => false} = event,
         state
       ) do
    request = prepare_request(event)

    with {:ok, _model_binding} <- authorize_grant(state, request) do
      complete_socket_prewarm(request, state)
    end
  end

  # Connection-local continuation is a transport fact, so it resolves before the
  # request kind is known. Every later owner then reads the history the caller
  # named, and none of them interprets `previous_response_id` again.
  defp handle_socket_event(%{"type" => "response.create"} = event, state) do
    request =
      event
      |> prepare_request()
      |> CodexModelBinding.apply(Map.get(state, :codex_model_binding))

    with {:ok, model_binding} <- authorize_grant(state, request),
         {:ok, request, socket_context} <- prepare_response_create_request(state, request) do
      if Compaction.compaction_trigger?(request) do
        serve_compaction_trigger(state, request)
      else
        open_response_create_stream(state, request, socket_context, model_binding)
      end
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

  # A policy refusal keeps its own name so a missing Client or Human reads as
  # access denied, not as a missing resource.
  defp authorize_grant(%{oidc_grant: %Grant{access_token: access_token}}, request) do
    case Grant.authorize(access_token, request["model"]) do
      {:ok, grant} -> {:ok, grant.model_binding}
      {:error, :invalid_oidc_access} = error -> error
      {:error, reason} -> {:error, {:oidc_access_denied, reason}}
    end
  end

  defp authorize_grant(_state, _request), do: {:ok, nil}

  # AIGateway response stream

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
        event = error_frame(reason)
        push_text_chunks(chunks ++ [Ankole.JSON.encode!(event)], clear_active_stream(state))
    end
  end

  def handle_info(
        {:ai_gateway_response_stream, ref, :events, events, {:terminal, nil}},
        %{active_stream: %{ref: ref}} = state
      ) do
    state = clear_active_stream(state)
    chunks = Enum.map(events, &{:text, Ankole.JSON.encode!(&1)})
    {:stop, :stateful_commit_failed, 1011, chunks, state}
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

  # The owner is gone, so no terminal will arrive. One error frame closes the
  # response and the connection stays open for the next request.
  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{active_stream: %{monitor: monitor}} = state
      ) do
    event = error_frame({:response_stream_closed, reason})
    {:push, {:text, Ankole.JSON.encode!(event)}, clear_active_stream(state)}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(
        reason,
        %{subject_uid: subject_uid, active_stream: %{stream: stream} = active_stream}
      ) do
    Logging.warning(
      "ai_gateway.responses_socket_interrupted",
      "AI Gateway response socket closed with an active stream",
      %{
        subject_uid: subject_uid,
        actor_event_id: active_stream[:actor_event_id],
        model: active_stream[:model],
        duration_ms: active_stream_duration_ms(active_stream),
        termination_reason: termination_reason(reason)
      }
    )

    _ = AIGateway.cancel_response_stream(stream, "socket_terminated")
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp open_active_stream(state, request, model_binding) do
    case safe_open_websocket_stream(state, request, model_binding) do
      {:ok, stream, _meta} ->
        case AIGateway.read_response_stream(stream, 1) do
          :ok ->
            {:ok,
             %{
               ref: stream.ref,
               stream: stream,
               monitor: ResponseStream.monitor(stream),
               request_input: Map.get(request, "input"),
               actor_event_id: get_in(request, ["metadata", "actor_event_id"]),
               model: Map.get(request, "model"),
               started_at_ms: System.monotonic_time(:millisecond)
             }}

          {:error, reason} ->
            _ = AIGateway.cancel_response_stream(stream, "provider_stream_initial_read_failed")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_open_websocket_stream(state, request, model_binding) do
    AIGateway.open_websocket_stream(state.subject_uid, request,
      model_binding: model_binding,
      request_context: Map.get(state, :request_context, %{}),
      subject_type: Map.get(state, :subject_type)
    )
  rescue
    error ->
      {:error, {:exception, error.__struct__, Exception.message(error)}}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  # Validation helpers

  defp ensure_no_active_stream(%{active_stream: _stream} = state) do
    {:error,
     %{
       event:
         request_error_frame(
           "response_in_progress",
           "AIGateway Responses WebSocket already has an active response.",
           status: 409
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
        {:error, %{event: request_error_frame(code, message, param: param), state: state}}

      {:error, _reason} ->
        {:error,
         %{
           event:
             request_error_frame("invalid_request_error", "WebSocket message must be valid JSON."),
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

  defp clear_active_stream(%{active_stream: active} = state) do
    case Map.get(active, :monitor) do
      nil -> :ok
      monitor -> Process.demonitor(monitor, [:flush])
    end

    Map.delete(state, :active_stream)
  end

  defp clear_active_stream(state), do: state

  defp active_stream_duration_ms(%{started_at_ms: started_at_ms})
       when is_integer(started_at_ms) do
    max(System.monotonic_time(:millisecond) - started_at_ms, 0)
  end

  defp active_stream_duration_ms(_active_stream), do: nil

  defp termination_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp termination_reason({reason, _details}) when is_atom(reason),
    do: Atom.to_string(reason)

  defp termination_reason(_reason), do: "unknown"

  defp push_text_chunks([], state), do: {:ok, state}
  defp push_text_chunks([chunk], state), do: {:push, {:text, chunk}, state}

  defp push_text_chunks(chunks, state),
    do: {:push, Enum.map(chunks, &{:text, &1}), state}

  defp complete_socket_prewarm(request, state) do
    response_id = "tmp_resp_#{UUIDv7.autogenerate()}"
    now = DateTime.utc_now() |> DateTime.to_unix()

    created_response = %{
      "id" => response_id,
      "object" => "response",
      "created_at" => now,
      "completed_at" => nil,
      "status" => "in_progress",
      "output" => [],
      "usage" => nil
    }

    completed_response = %{
      created_response
      | "completed_at" => now,
        "status" => "completed",
        "usage" => zero_usage()
    }

    events = [
      %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => created_response
      },
      %{
        "type" => "response.completed",
        "sequence_number" => 1,
        "response" => completed_response
      }
    ]

    state =
      put_socket_response_history(state, response_id, %{
        response: completed_response,
        items: response_input_items(Map.get(request, "input"))
      })

    events
    |> Enum.map(&Ankole.JSON.encode!/1)
    |> push_text_chunks(state)
  end

  defp open_response_create_stream(state, request, socket_context, model_binding) do
    with {:ok, active_stream} <- open_active_stream(state, request, model_binding) do
      active_stream = Map.merge(active_stream, socket_context)
      {:ok, Map.put(state, :active_stream, active_stream)}
    end
  end

  # AIGateway serves the compaction protocol itself, so the trigger never opens
  # a Provider stream here. The reply is the same shape every consumer already
  # reads: one compaction output item and one terminal.
  #
  # The reply ID stays out of the connection history on purpose. What a caller
  # keeps after compaction is the caller's own decision, so AIGateway cannot
  # name that history. A caller that continues from the reply sends its whole
  # input instead.
  defp serve_compaction_trigger(state, request) do
    case Compaction.compact_from_trigger(state.subject_uid, request) do
      {:ok, response} ->
        response
        |> Compaction.trigger_events()
        |> Enum.map(&Ankole.JSON.encode!/1)
        |> push_text_chunks(state)

      {:error, _reason} = error ->
        error
    end
  end

  defp zero_usage do
    %{
      "input_tokens" => 0,
      "input_tokens_details" => %{"cached_tokens" => 0},
      "output_tokens" => 0,
      "output_tokens_details" => %{"reasoning_tokens" => 0},
      "total_tokens" => 0
    }
  end

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

  # Every failure that AIGateway names is framed here from one projection; the
  # socket adds only the WebSocket envelope and the transport phase.
  defp error_frame(reason, opts \\ []) do
    reason
    |> FailureDiagnostics.project(opts)
    |> wrapped_error_frame()
  end

  defp request_error_frame(code, message, opts \\ []) do
    wrapped_error_frame(%{
      status: Keyword.get(opts, :status, 400),
      headers: %{},
      error: %{
        "type" => "invalid_request_error",
        "code" => code,
        "message" => message,
        "param" => Keyword.get(opts, :param)
      }
    })
  end

  defp wrapped_error_frame(%{status: status, headers: headers, error: error}) do
    %{"type" => "error", "sequence_number" => 0, "status" => status, "error" => error}
    |> put_frame_headers(headers)
  end

  defp put_frame_headers(frame, headers) when map_size(headers) == 0, do: frame
  defp put_frame_headers(frame, headers), do: Map.put(frame, "headers", headers)

  defp openai_error_event(%OpenAIError{} = error) do
    %{
      "type" => "error",
      "sequence_number" => 0,
      "code" => error.code,
      "message" => error.message,
      "param" => error.param
    }
  end

  defp tool_results_recorded_event(response_body) do
    %{
      "type" => "response.tool_results.recorded",
      "sequence_number" => 0,
      "response_id" => response_body["id"],
      "response" => response_body
    }
  end
end
