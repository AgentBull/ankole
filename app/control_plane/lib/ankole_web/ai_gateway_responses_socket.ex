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
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Logging
  alias Ankole.SignalsGateway.AIGatewayLink

  @socket_response_history_limit 32

  # ─────────────────────────────────────────────────────────────────
  # Connection lifecycle
  # ─────────────────────────────────────────────────────────────────

  @impl WebSock
  def init(%{subject_uid: _subject_uid, subject_type: _subject_type} = state), do: {:ok, state}

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

      {:error, {:stateful_wire_unsupported, provider_kind, api_resolver}} ->
        event =
          error_event(
            422,
            "stateful_wire_unsupported",
            "Stateful conversations replay history as Responses items. Provider " <>
              "'#{provider_kind}' uses the '#{api_resolver}' wire, which cannot replay " <>
              "that history. Select a provider on the openai_responses or " <>
              "openai_chat_completions wire, or use this provider for stateless requests.",
            "model"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:unknown_model_selector, _capability, selector}} ->
        event =
          error_event(
            422,
            "unknown_model_selector",
            "Unknown model selector: #{selector}.",
            "model"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:model_binding_not_configured, capability, name}} ->
        event =
          error_event(
            422,
            "model_binding_not_configured",
            "#{capability}.#{name} is not configured.",
            "model"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :model_profile_not_configured} ->
        event =
          error_event(
            422,
            "model_profile_not_configured",
            "Model profile is not configured for this Agent.",
            "model"
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:credential_pool_exhausted, details}} when is_map(details) ->
        event = credential_pool_exhausted_event(details)
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:upstream_response_failed, status, body}} ->
        event = upstream_response_failed_event(status, body)
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:upstream_response_failed, status, body, _headers}} ->
        event = upstream_response_failed_event(status, body)
        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, {:invalid_upstream_response, status, body}} ->
        event = invalid_upstream_response_event(status, body)
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

      # Compaction is a WebSocket capability, so its refusals are named here.
      # A generic gateway failure would hide which request the caller must fix.
      {:error, reason} when reason in [:missing_model, :missing_input] ->
        event =
          error_event(
            400,
            Atom.to_string(reason),
            "compaction_trigger requires #{String.replace(Atom.to_string(reason), "missing_", "")}."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, :no_compaction_candidate} ->
        event =
          error_event(
            400,
            "no_compaction_candidate",
            "input has no compactable items after the last compaction item."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, reason}
      when reason in [:empty_compaction_summary, :invalid_summary_shape] ->
        event =
          error_event(
            502,
            Atom.to_string(reason),
            "upstream provider returned no usable compaction summary."
          )

        {:push, {:text, Ankole.JSON.encode!(event)}, state}

      {:error, _reason} ->
        event = error_event(502, "ai_gateway_request_failed", "AIGateway request failed.")
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

  defp handle_socket_event(
         %{"type" => "response.create", "generate" => false} = event,
         state
       ) do
    event
    |> prepare_request()
    |> complete_socket_prewarm(state)
  end

  # Connection-local continuation is a transport fact, so it resolves before the
  # request kind is known. Every later owner then reads the history the caller
  # named, and none of them interprets `previous_response_id` again.
  defp handle_socket_event(%{"type" => "response.create"} = event, state) do
    request =
      event
      |> prepare_request()
      |> CodexModelBinding.apply(Map.get(state, :codex_model_binding))

    with {:ok, request, socket_context} <- prepare_response_create_request(state, request) do
      if Compaction.compaction_trigger?(request) do
        serve_compaction_trigger(state, request)
      else
        open_response_create_stream(state, request, socket_context)
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
            safe_failure_details(reason, "stream_read")
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

  defp open_active_stream(state, request) do
    case safe_open_websocket_stream(state, request) do
      {:ok, stream, _meta} ->
        case AIGateway.read_response_stream(stream, 1) do
          :ok ->
            {:ok,
             %{
               ref: stream.ref,
               stream: stream,
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

  defp safe_open_websocket_stream(state, request) do
    AIGateway.open_websocket_stream(state.subject_uid, request,
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

  defp open_response_create_stream(state, request, socket_context) do
    with {:ok, active_stream} <- open_active_stream(state, request) do
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

  defp credential_pool_exhausted_event(details) do
    retry_at = pool_retry_at(details)

    %{
      "type" => "error",
      "sequence_number" => 0,
      "status" => 429,
      "headers" => pool_retry_headers(retry_at),
      "error" =>
        %{
          "type" => "usage_limit_reached",
          "code" => "credential_pool_exhausted",
          "message" => pool_exhausted_message(retry_at),
          "details_json" => public_pool_exhausted_details(retry_at)
        }
        |> maybe_put_resets_at(retry_at)
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
    reason = {:upstream_response_failed, status, body}
    classification = FailureDiagnostics.classify(reason)

    error_event(
      public_upstream_status(status),
      "upstream_response_failed",
      FailureDiagnostics.public_message(classification),
      nil,
      safe_failure_details(reason, "socket_open")
    )
  end

  defp invalid_upstream_response_event(status, body) do
    error_event(
      502,
      "invalid_upstream_response",
      "Provider returned an invalid upstream response.",
      nil,
      safe_failure_details({:invalid_upstream_response, status, body}, "socket_open")
    )
  end

  defp public_upstream_status(status) when is_integer(status) and status >= 400 and status <= 599,
    do: status

  defp public_upstream_status(_status), do: 502

  defp universal_ai_request_failed_event(details) do
    reason = {:universal_ai_request_failed, details}
    classification = FailureDiagnostics.classify(reason)

    {status, code, message} =
      case classification do
        %{failure_kind: :timeout} ->
          {504, "upstream_timeout", "Upstream provider timed out."}

        %{failure_kind: :transport} ->
          {502, "upstream_transport_failed", "Upstream provider request failed."}

        %{failure_kind: :provider_response, provider_status: status} ->
          {public_upstream_status(status), "upstream_response_failed",
           FailureDiagnostics.public_message(classification)}

        _classification ->
          {502, "ai_gateway_request_failed", "AIGateway request failed."}
      end

    error_event(
      status,
      code,
      message,
      nil,
      safe_failure_details(reason, "socket_open")
    )
  end

  defp safe_failure_details(reason, stage) do
    reason
    |> FailureDiagnostics.classify()
    |> Map.take([
      :error_code,
      :error_stage,
      :provider_status,
      :http_status,
      :provider_error_code,
      :provider_error_type,
      :retryable
    ])
    |> Enum.reduce(%{"stage" => stage}, fn {key, value}, details ->
      if is_nil(value) do
        details
      else
        Map.put(details, Atom.to_string(key), value)
      end
    end)
  end

  defp pool_retry_at(%{"retry_at" => retry_at}) when is_binary(retry_at) do
    case DateTime.from_iso8601(retry_at) do
      {:ok, parsed, _offset} -> parsed
      _error -> nil
    end
  end

  defp pool_retry_at(_details), do: nil

  defp pool_retry_headers(%DateTime{} = retry_at) do
    retry_after = max(DateTime.diff(retry_at, DateTime.utc_now(), :second), 0)

    %{
      "retry-after" => Integer.to_string(retry_after),
      "x-codex-primary-reset-at" => Integer.to_string(DateTime.to_unix(retry_at))
    }
  end

  defp pool_retry_headers(nil), do: %{}

  defp pool_exhausted_message(%DateTime{} = retry_at),
    do:
      "All credentials in this provider pool are unavailable. retry_at=#{DateTime.to_iso8601(retry_at)}"

  defp pool_exhausted_message(nil),
    do: "All credentials in this provider pool are unavailable. Try again later."

  defp public_pool_exhausted_details(%DateTime{} = retry_at),
    do: %{"retry_at" => DateTime.to_iso8601(retry_at)}

  defp public_pool_exhausted_details(nil), do: %{}

  defp maybe_put_resets_at(error, %DateTime{} = retry_at),
    do: Map.put(error, "resets_at", DateTime.to_unix(retry_at))

  defp maybe_put_resets_at(error, nil), do: error
end
