defmodule AnkoleWeb.AIGatewayResponsesSocket do
  @moduledoc """
  Raw OpenResponses WebSocket transport for AIGateway.
  """

  @behaviour WebSock

  alias Ankole.AIGateway

  @http_only_websocket_fields ~w(stream stream_options background)

  @impl WebSock
  def init(%{subject_uid: subject_uid, subject_type: subject_type}) do
    {:ok, %{subject_uid: subject_uid, subject_type: subject_type, response_cache: %{}}}
  end

  def init(%{agent_uid: agent_uid}) do
    init(%{subject_uid: agent_uid, subject_type: "agent"})
  end

  @impl WebSock
  def handle_in({payload, [opcode: :text]}, state) do
    with {:ok, event} <- decode_create_event(payload, state),
         {:ok, request, state} <- prepare_request(event, state),
         {:ok, events, response} <- AIGateway.response_events(state.subject_uid, request) do
      state = maybe_cache_response(event, request, response.body, state)
      {:push, response_frames(events), state}
    else
      {:error, %{event: event, state: state}} ->
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

  @impl WebSock
  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, _state), do: :ok

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

  defp prepare_request(event, state) do
    event
    |> Map.delete("type")
    |> then(&prepare_previous_response(&1, state))
  end

  defp prepare_previous_response(%{"previous_response_id" => id} = request, state)
       when is_binary(id) and id != "" do
    case Map.fetch(state.response_cache, id) do
      {:ok, cached} ->
        case validate_function_outputs(request, cached) do
          :ok ->
            {:ok, expand_continuation_request(request, cached), state}

          {:error, message} ->
            state = %{state | response_cache: Map.delete(state.response_cache, id)}

            {:error,
             %{
               event: error_event(400, "invalid_request_error", message),
               state: state
             }}
        end

      :error ->
        {:error,
         %{
           event:
             error_event(
               400,
               "previous_response_not_found",
               "Previous response with id '#{id}' was not found in this WebSocket connection.",
               "previous_response_id"
             ),
           state: state
         }}
    end
  end

  defp prepare_previous_response(request, state), do: {:ok, request, state}

  defp expand_continuation_request(request, cached) do
    input =
      cached.input ++
        cached.output ++
        input_items(Map.get(request, "input"))

    request
    |> Map.delete("previous_response_id")
    |> Map.put("input", input)
  end

  defp validate_function_outputs(request, cached) do
    output_call_ids = function_call_output_ids(Map.get(request, "input"))
    previous_call_ids = function_call_ids(cached.output)

    case Enum.find(output_call_ids, &(&1 not in previous_call_ids)) do
      nil -> :ok
      call_id -> {:error, "No matching function_call output item exists for call_id #{call_id}."}
    end
  end

  defp maybe_cache_response(event, request, response_body, state) do
    if Map.get(event, "store") == false and is_binary(response_body["id"]) do
      cache_entry = %{
        input: input_items(Map.get(request, "input")),
        output: output_items(response_body),
        response: response_body
      }

      %{state | response_cache: Map.put(state.response_cache, response_body["id"], cache_entry)}
    else
      state
    end
  end

  defp response_frames(events) when is_list(events) do
    Enum.map(events, fn event ->
      {:text, Ankole.JSON.encode!(event)}
    end)
  end

  defp input_items(nil), do: []

  defp input_items(input) when is_binary(input),
    do: [%{"type" => "message", "role" => "user", "content" => input}]

  defp input_items(input) when is_list(input), do: input

  defp input_items(input),
    do: [%{"type" => "message", "role" => "user", "content" => inspect(input)}]

  defp output_items(%{"output" => output}) when is_list(output), do: output
  defp output_items(_response), do: []

  defp function_call_ids(items) when is_list(items) do
    items
    |> Enum.filter(&match?(%{"type" => "function_call"}, &1))
    |> Enum.flat_map(fn
      %{"call_id" => call_id} when is_binary(call_id) -> [call_id]
      _item -> []
    end)
  end

  defp function_call_ids(_items), do: []

  defp function_call_output_ids(input) do
    input
    |> input_items()
    |> Enum.filter(&match?(%{"type" => "function_call_output"}, &1))
    |> Enum.flat_map(fn
      %{"call_id" => call_id} when is_binary(call_id) -> [call_id]
      _item -> []
    end)
  end

  defp error_event(status, code, message, param \\ nil) do
    %{
      "type" => "error",
      # Local WebSocket validation errors happen before any model output exists.
      # Sequence 0 keeps the frame compatible with the Responses stream schema
      # used by clients that share their SSE and WebSocket event decoders.
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
