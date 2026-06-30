defmodule AnkoleWeb.AIGatewayResponsesSocket do
  @moduledoc """
  Raw OpenResponses WebSocket transport for AIGateway.
  """

  @behaviour WebSock

  alias Ankole.AIGateway
  alias Ankole.Kernel.UniversalAIClient

  @http_only_websocket_fields ~w(stream stream_options background)

  @impl WebSock
  def init(%{subject_uid: subject_uid, subject_type: subject_type}) do
    {:ok, %{subject_uid: subject_uid, subject_type: subject_type}}
  end

  def init(%{agent_uid: agent_uid}) do
    init(%{subject_uid: agent_uid, subject_type: "agent"})
  end

  @impl WebSock
  def handle_in({payload, [opcode: :text]}, state) do
    with :ok <- ensure_no_active_stream(state),
         {:ok, event} <- decode_create_event(payload, state),
         request <- prepare_request(event),
         {:ok, stream, _meta} <- AIGateway.open_websocket_stream(state.subject_uid, request),
         :ok <- UniversalAIClient.read(stream, 1) do
      {:ok, Map.put(state, :active_stream, stream)}
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
  def handle_info(
        {:universal_ai_client, ref, :chunk, _seq, :websocket_text, chunk},
        %{active_stream: %{ref: ref} = stream} = state
      ) do
    case UniversalAIClient.read(stream, 1) do
      :ok ->
        {:push, {:text, chunk}, state}

      {:error, _reason} ->
        {:push, {:text, chunk}, clear_active_stream(state)}
    end
  end

  def handle_info(
        {:universal_ai_client, ref, :chunk, _seq, kind, _chunk},
        %{active_stream: %{ref: ref} = stream} = state
      ) do
    _ = UniversalAIClient.cancel(stream)
    state = clear_active_stream(state)

    event =
      error_event(
        502,
        "unexpected_downstream_chunk_kind",
        "UniversalAIClient stream produced #{inspect(kind)} for WebSocket transport"
      )

    {:push, {:text, Ankole.JSON.encode!(event)}, state}
  end

  def handle_info(
        {:universal_ai_client, ref, :done, _summary},
        %{active_stream: %{ref: ref}} = state
      ) do
    {:ok, clear_active_stream(state)}
  end

  def handle_info(
        {:universal_ai_client, ref, :error, _error},
        %{active_stream: %{ref: ref}} = state
      ) do
    {:ok, clear_active_stream(state)}
  end

  def handle_info(
        {:universal_ai_client, ref, :aborted},
        %{active_stream: %{ref: ref}} = state
      ) do
    {:ok, clear_active_stream(state)}
  end

  def handle_info({:universal_ai_client, _ref, _kind, _payload}, state), do: {:ok, state}
  def handle_info({:universal_ai_client, _ref, _kind}, state), do: {:ok, state}

  def handle_info({:universal_ai_client, _ref, _kind, _seq, _chunk_kind, _binary}, state),
    do: {:ok, state}

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  def terminate(_reason, %{active_stream: stream}) do
    _ = UniversalAIClient.cancel(stream)
    :ok
  end

  def terminate(_reason, _state), do: :ok

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

  defp prepare_request(event) do
    event
    |> Map.delete("type")
    |> Map.delete("previous_response_id")
  end

  defp clear_active_stream(state), do: Map.delete(state, :active_stream)

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
