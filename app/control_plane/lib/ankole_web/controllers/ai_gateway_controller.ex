defmodule AnkoleWeb.AIGatewayController do
  alias Ankole.AIGateway.FailureResponse
  alias Ankole.AIGateway.CompactionRequests

  @moduledoc """
  Principal-authenticated AIGateway runtime API.
  """

  use AnkoleWeb, :controller

  alias Ankole.AIGateway
  alias Ankole.Sessions.CodexModelBinding
  alias Ankole.AIGateway.CodexModels
  alias Ankole.AIGateway.RequestContext
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.OIDC.Grant

  def options(conn, _params), do: send_resp(conn, 204, "")

  def responses(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid
    subject_type = conn.assigns.current_ai_gateway_subject_type
    request_context = RequestContext.from_headers(conn.req_headers, "http")

    with {:ok, request, request_context, brain_context} <-
           bind_codex_request(conn, request, request_context) do
      response_opts =
        conn
        |> response_opts(subject_type, request_context)
        |> Keyword.put(:brain_context, brain_context)

      cond do
        # The trigger is a request item, so it must not reach the provider path
        # on any transport. Streaming renders the same reply as events.
        CompactionRequests.compaction_trigger?(request) ->
          compaction_trigger_response(
            conn,
            subject_uid,
            request,
            AIGateway.stream_requested?(request),
            response_opts
          )

        AIGateway.stream_requested?(request) ->
          stream_response(conn, subject_uid, request, response_opts)

        true ->
          case AIGateway.create_response(subject_uid, request, response_opts) do
            {:ok, %{body: body}} -> json(conn, body)
            {:error, reason} -> error(conn, reason)
          end
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def retrieve_response(conn, %{"response_id" => response_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.retrieve_response(subject_uid, response_id) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  def embeddings(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_embeddings(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  def rerank(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_rerank(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  def web_search(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_web_search(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  def web_fetch(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_web_fetch(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  def models(conn, params) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid
    subject_type = conn.assigns.current_ai_gateway_subject_type
    grant = conn.assigns[:oidc_grant]

    {:ok, body} =
      case grant do
        %Grant{client: client} ->
          AIGateway.list_model_aliases(client.model_aliases, params)

        nil ->
          if CodexModels.codex_manifest_request?(params),
            do: CodexModels.manifest(subject_uid, subject_type),
            else: AIGateway.list_models(subject_uid, subject_type, params)
      end

    json(conn, body)
  end

  defp compaction_trigger_response(conn, subject_uid, request, streaming?, opts) do
    case with(
           :ok <- AIGateway.ensure_stateless_request(request),
           do:
             CompactionRequests.compact_from_trigger(
               subject_uid,
               request,
               Keyword.take(opts, [:subject_type, :request_context])
             )
         ) do
      {:ok, body} when not streaming? ->
        json(conn, body)

      {:ok, body} ->
        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)

        chunks =
          Enum.map(CompactionRequests.trigger_events(body), &encode_sse_event/1) ++
            [done_sse_chunk()]

        case chunk_all(conn, chunks) do
          {:ok, conn} -> conn
          {:error, conn} -> conn
        end

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp stream_response(conn, subject_uid, request, response_opts) do
    case AIGateway.open_sse_stream(subject_uid, request, response_opts) do
      {:ok, stream, _meta} ->
        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> send_chunked(200)

        stream_sse_events(conn, stream)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp response_opts(conn, subject_type, request_context) do
    model_binding =
      case conn.assigns[:oidc_grant] do
        %Grant{model_binding: binding} -> binding
        nil -> nil
      end

    [
      request_context: request_context,
      subject_type: subject_type,
      model_binding: model_binding
    ]
  end

  # A stream that ends without its terminal, including an owner that exits, is
  # closed with one error event so the client never waits on a dead stream.
  defp stream_sse_events(conn, stream) do
    case ResponseStream.next(stream, :infinity) do
      {:ok, events, :continue} ->
        case chunk_all(conn, Enum.map(events, &encode_sse_event/1)) do
          {:ok, conn} ->
            stream_sse_events(conn, stream)

          {:error, conn} ->
            _ = AIGateway.cancel_response_stream(stream, "sse_client_disconnected")
            conn
        end

      {:ok, events, {:terminal, _outcome}} ->
        finish_sse(conn, Enum.map(events, &encode_sse_event/1))

      {:error, reason} ->
        finish_sse(conn, [encode_sse_event(sse_error_event(reason))])
    end
  end

  defp finish_sse(conn, chunks) do
    case chunk_all(conn, chunks ++ [done_sse_chunk()]) do
      {:ok, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp sse_error_event(reason) do
    %{status: status, error: error} = FailureResponse.project(reason)
    %{"type" => "error", "sequence_number" => 0, "status" => status, "error" => error}
  end

  defp chunk_all(conn, chunks) do
    Enum.reduce_while(chunks, {:ok, conn}, fn chunk, {:ok, conn} ->
      case Plug.Conn.chunk(conn, chunk) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _reason} -> {:halt, {:error, conn}}
      end
    end)
  end

  defp encode_sse_event(%{"type" => type} = event),
    do: "event: #{type}\ndata: #{Ankole.JSON.encode!(event)}\n\n"

  defp done_sse_chunk, do: "data: [DONE]\n\n"

  defp bind_codex_request(conn, request, request_context) do
    case get_req_header(conn, CodexModelBinding.header_name()) do
      [] ->
        {:ok, request, request_context, nil}

      [encoded] ->
        with {:ok, binding} <- CodexModelBinding.decode(encoded),
             {:ok, brain_context} <-
               CodexModelBinding.brain_context(
                 conn.assigns.current_ai_gateway_subject_uid,
                 binding
               ) do
          {:ok, CodexModelBinding.apply(request, binding, request_context),
           CodexModelBinding.request_context(binding, request_context), brain_context}
        end

      _values ->
        {:error, :invalid_codex_model_binding}
    end
  end

  # One projection names every failure; the controller adds only the HTTP
  # status, response headers, and JSON envelope.
  defp error(conn, reason) do
    %{status: status, headers: headers, error: error} = FailureResponse.project(reason)

    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
    |> put_status(status)
    |> json(%{"error" => error})
  end
end
