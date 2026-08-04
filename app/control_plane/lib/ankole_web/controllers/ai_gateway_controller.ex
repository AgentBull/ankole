defmodule AnkoleWeb.AIGatewayController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Principal-authenticated AIGateway runtime API.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIGateway
  alias Ankole.AIGateway.CodexModelBinding
  alias Ankole.AIGateway.CodexModels
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.RequestContext
  alias OpenAPISpex.Schema

  @json_object %Schema{type: :object, additionalProperties: true}

  tags(["AIGateway"])
  security([%{"aiGatewayBearer" => []}, %{"consoleBearer" => []}])

  operation(:responses,
    summary: "Create a stateless OpenResponses response",
    request_body: {"OpenResponses request", "application/json", @json_object, required: true},
    responses: [
      ok: {"OpenResponses response", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def responses(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid
    request_context = RequestContext.from_headers(conn.req_headers, "http")

    with {:ok, request} <- bind_codex_request(conn, request) do
      case AIGateway.stream_requested?(request) do
        true ->
          stream_response(conn, subject_uid, request, request_context)

        false ->
          case AIGateway.create_response(subject_uid, request, request_context: request_context) do
            {:ok, %{body: body}} -> json(conn, body)
            {:error, reason} -> error(conn, reason)
          end
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:retrieve_response,
    summary: "Retrieve a stored stateful OpenResponses response",
    parameters: [
      response_id: [
        in: :path,
        type: :string,
        required: true,
        description: "Stored response id, formatted as resp_{uuid}"
      ]
    ],
    responses: [
      ok: {"OpenResponses response", "application/json", @json_object},
      not_found: {"Not found", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def retrieve_response(conn, %{"response_id" => response_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.retrieve_response(subject_uid, response_id) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:compact_response,
    summary: "Create a stateful compaction response",
    request_body:
      {"OpenResponses compact request", "application/json", @json_object, required: true},
    responses: [
      ok: {"OpenResponses response", "application/json", @json_object},
      bad_request: {"Invalid compact request", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def compact_response(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    with {:ok, request} <- bind_codex_request(conn, request) do
      case AIGateway.compact_response(subject_uid, request) do
        {:ok, %{body: body}} -> json(conn, body)
        {:error, reason} -> error(conn, reason)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:embeddings,
    summary: "Create embeddings through AIGateway",
    request_body: {"Embedding request", "application/json", @json_object, required: true},
    responses: [
      ok: {"Embedding response", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def embeddings(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_embeddings(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:rerank,
    summary: "Create a rerank result through AIGateway",
    request_body: {"Rerank request", "application/json", @json_object, required: true},
    responses: [
      ok: {"Rerank response", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def rerank(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_rerank(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:web_tools,
    summary: "List provider-backed web tools available to this AIGateway subject",
    responses: [
      ok: {"Web tool availability", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def web_tools(conn, _params) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    {:ok, body} = AIGateway.web_tools(subject_uid)
    json(conn, body)
  end

  operation(:web_search,
    summary: "Search the web through AIGateway",
    request_body: {"Web search request", "application/json", @json_object, required: true},
    responses: [
      ok: {"Web search response", "application/json", @json_object},
      bad_request: {"Invalid web search request", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def web_search(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_web_search(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:web_fetch,
    summary: "Fetch web pages through AIGateway",
    request_body: {"Web fetch request", "application/json", @json_object, required: true},
    responses: [
      ok: {"Web fetch response", "application/json", @json_object},
      bad_request: {"Invalid web fetch request", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def web_fetch(conn, _params) do
    request = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case AIGateway.create_web_fetch(subject_uid, request) do
      {:ok, %{body: body}} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:models,
    summary: "List AIGateway model selectors",
    parameters: [
      output_modalities: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated output modalities or all"
      ],
      input_modalities: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated input modalities"
      ],
      supported_parameters: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated supported request parameters"
      ],
      sort: [
        in: :query,
        type: :string,
        required: false,
        description: "OpenRouter-style sort key"
      ],
      q: [
        in: :query,
        type: :string,
        required: false,
        description: "Free-text selector search"
      ],
      context: [
        in: :query,
        type: :integer,
        required: false,
        description: "Minimum context length"
      ],
      min_price: [
        in: :query,
        type: :number,
        required: false,
        description: "Minimum prompt price"
      ],
      max_price: [
        in: :query,
        type: :number,
        required: false,
        description: "Maximum prompt price"
      ]
    ],
    responses: [
      ok: {"OpenRouter-style model list", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def models(conn, params) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid
    subject_type = conn.assigns.current_ai_gateway_subject_type

    {:ok, body} =
      if CodexModels.codex_manifest_request?(params) do
        CodexModels.manifest(subject_uid, subject_type)
      else
        AIGateway.list_models(subject_uid, subject_type, params)
      end

    json(conn, body)
  end

  defp stream_response(conn, subject_uid, request, request_context) do
    case AIGateway.open_sse_stream(subject_uid, request, request_context: request_context) do
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

  defp stream_sse_events(conn, stream) do
    case AIGateway.read_response_stream(stream, 1) do
      :ok ->
        receive do
          {:ai_gateway_response_stream, ref, :events, events, :continue}
          when ref == stream.ref ->
            case chunk_all(conn, Enum.map(events, &encode_sse_event/1)) do
              {:ok, conn} ->
                stream_sse_events(conn, stream)

              {:error, conn} ->
                _ = AIGateway.cancel_response_stream(stream, "sse_client_disconnected")
                conn
            end

          {:ai_gateway_response_stream, ref, :events, events, {:terminal, _outcome}}
          when ref == stream.ref ->
            chunks = Enum.map(events, &encode_sse_event/1) ++ [done_sse_chunk()]

            case chunk_all(conn, chunks) do
              {:ok, conn} -> conn
              {:error, conn} -> conn
            end
        end

      {:error, _reason} ->
        conn
    end
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

  defp bind_codex_request(conn, request) do
    case get_req_header(conn, CodexModelBinding.header_name()) do
      [] ->
        {:ok, request}

      [encoded] ->
        with {:ok, binding} <- CodexModelBinding.decode(encoded) do
          responses_lite? =
            get_req_header(conn, CodexModelBinding.responses_lite_header_name()) == ["true"]

          {:ok, CodexModelBinding.apply(request, binding, responses_lite?: responses_lite?)}
        end

      _values ->
        {:error, :invalid_codex_model_binding}
    end
  end

  defp error(conn, %OpenAIError{} = error) do
    conn
    |> put_status(error.status)
    |> json(OpenAIError.envelope(error))
  end

  defp error(conn, {:credential_pool_exhausted, details}) when is_map(details) do
    retry_at = pool_retry_at(details)

    conn
    |> put_pool_retry_headers(retry_at)
    |> put_status(429)
    |> json(%{
      error:
        %{
          type: "usage_limit_reached",
          code: "credential_pool_exhausted",
          message: pool_exhausted_message(retry_at),
          details_json: public_pool_exhausted_details(retry_at)
        }
        |> maybe_put_resets_at(retry_at)
    })
  end

  defp error(conn, reason) do
    {status, code, message} = error_tuple(reason)

    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp error_tuple(:missing_model), do: {400, "missing_model", "model is required"}
  defp error_tuple(:missing_input), do: {400, "missing_input", "input is required"}
  defp error_tuple(:missing_query), do: {400, "missing_query", "query is required"}
  defp error_tuple(:missing_urls), do: {400, "missing_urls", "urls is required"}
  defp error_tuple(:invalid_query), do: {400, "invalid_query", "query is too long"}

  defp error_tuple(:invalid_limit),
    do: {400, "invalid_limit", "limit must be an integer from 1 to 100"}

  defp error_tuple(:invalid_urls),
    do: {400, "invalid_urls", "urls must contain 1 to 5 public HTTPS URLs"}

  defp error_tuple(:invalid_embedding_input),
    do: {400, "invalid_embedding_input", "input must be text, token arrays, or input blocks"}

  defp error_tuple(:invalid_documents),
    do: {400, "invalid_documents", "documents must be a non-empty array"}

  defp error_tuple(:invalid_top_n), do: {400, "invalid_top_n", "top_n must be a positive integer"}

  defp error_tuple(:invalid_request_body),
    do: {400, "invalid_request_body", "JSON object body required"}

  defp error_tuple(:invalid_codex_model_binding),
    do: {400, "invalid_codex_model_binding", "Codex model binding is invalid"}

  defp error_tuple(:invalid_compaction_item),
    do: {400, "invalid_compaction_item", "input must contain exactly one compaction item"}

  defp error_tuple(:invalid_compaction_handle),
    do: {400, "invalid_compaction_handle", "compaction encrypted_content handle is invalid"}

  defp error_tuple(:no_compaction_candidate),
    do:
      {400, "no_compaction_candidate",
       "input has no compactable items after the last compaction item"}

  defp error_tuple(:compact_store_required),
    do:
      {400, "compact_store_required",
       "previous_response_id or conversation on /responses/compact requires store=true"}

  defp error_tuple(:invalid_anchor),
    do:
      {400, "invalid_previous_response_id",
       "previous_response_id must reference a stored response"}

  defp error_tuple(:invalid_conversation),
    do: {400, "invalid_conversation", "conversation must reference a stored conversation"}

  defp error_tuple({:stateful_http_field_forbidden, field}),
    do:
      {400, "stateful_responses_require_websocket",
       "#{field} is only supported on WebSocket response.create with store=true"}

  defp error_tuple(:provider_disabled), do: {422, "provider_disabled", "provider is disabled"}
  defp error_tuple(:not_found), do: {404, "not_found", "resource not found"}
  defp error_tuple(:agent_not_found), do: {404, "agent_not_found", "agent not found"}

  defp error_tuple({:unknown_model_selector, _capability, selector}),
    do: {422, "unknown_model_selector", "unknown model selector: #{selector}"}

  defp error_tuple({:model_binding_not_configured, capability, name}),
    do: {422, "model_binding_not_configured", "#{capability}.#{name} is not configured"}

  # A model name that is neither provider/model nor a configured profile reaches
  # here, because any valid profile name is a candidate once an Agent can own
  # custom profiles. That is a caller or configuration fault, not a server fault.
  defp error_tuple(:model_profile_not_configured),
    do: {422, "model_profile_not_configured", "model profile is not configured for this Agent"}

  defp error_tuple({:unsupported_capability, capability}),
    do: {422, "unsupported_capability", "provider does not support #{capability}"}

  defp error_tuple({:upstream_response_failed, status, body}) when is_integer(status),
    do:
      {upstream_public_status(status), "upstream_response_failed",
       upstream_error_message(status, body)}

  defp error_tuple({:upstream_response_failed, status, body, _headers})
       when is_integer(status),
       do: error_tuple({:upstream_response_failed, status, body})

  defp error_tuple({:invalid_upstream_response, status, _body}) when is_integer(status),
    do: {502, "invalid_upstream_response", "upstream provider returned an invalid response"}

  defp error_tuple(:invalid_response_stream_collect_timeout),
    do:
      {400, "invalid_response_stream_collect_timeout",
       "response stream collect timeout must be a positive integer"}

  defp error_tuple(:response_stream_collect_timeout),
    do: {504, "upstream_timeout", "upstream provider timed out"}

  defp error_tuple(:universal_ai_stream_ready_timeout),
    do: {504, "upstream_timeout", "upstream provider timed out"}

  defp error_tuple(:response_stream_missing_terminal_response),
    do: {502, "invalid_upstream_response", "upstream provider closed without a terminal response"}

  defp error_tuple(:response_stream_closed),
    do: {502, "upstream_transport_failed", "upstream provider stream closed unexpectedly"}

  defp error_tuple({:response_stream_closed, _reason}),
    do: error_tuple(:response_stream_closed)

  defp error_tuple({:universal_ai_request_failed, _details} = reason) do
    case FailureDiagnostics.classify(reason) do
      %{failure_kind: :timeout} ->
        {504, "upstream_timeout", "upstream provider timed out"}

      %{failure_kind: :transport} ->
        {502, "upstream_transport_failed", "upstream provider request failed"}

      _classification ->
        {502, "ai_gateway_request_failed", "upstream provider request failed"}
    end
  end

  defp error_tuple({reason, details}) when is_atom(reason),
    do: {422, Atom.to_string(reason), inspect(details)}

  defp error_tuple(reason) when is_atom(reason),
    do: {422, Atom.to_string(reason), Atom.to_string(reason)}

  defp error_tuple(reason), do: {422, "ai_gateway_request_failed", inspect(reason)}

  defp upstream_public_status(status) when status in 400..499, do: status
  defp upstream_public_status(_status), do: 502

  defp upstream_error_message(_status, %{"error" => %{"message" => message}})
       when is_binary(message),
       do: message

  defp upstream_error_message(status, _body),
    do: "upstream provider returned HTTP #{status}"

  defp pool_retry_at(%{"retry_at" => retry_at}) when is_binary(retry_at) do
    case DateTime.from_iso8601(retry_at) do
      {:ok, parsed, _offset} -> parsed
      _error -> nil
    end
  end

  defp pool_retry_at(_details), do: nil

  defp put_pool_retry_headers(conn, %DateTime{} = retry_at) do
    retry_after = max(DateTime.diff(retry_at, DateTime.utc_now(), :second), 0)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_resp_header("x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(retry_at)))
  end

  defp put_pool_retry_headers(conn, nil), do: conn

  defp pool_exhausted_message(%DateTime{} = retry_at),
    do:
      "All credentials in this provider pool are unavailable. retry_at=#{DateTime.to_iso8601(retry_at)}"

  defp pool_exhausted_message(nil),
    do: "All credentials in this provider pool are unavailable. Try again later."

  defp public_pool_exhausted_details(%DateTime{} = retry_at),
    do: %{retry_at: DateTime.to_iso8601(retry_at)}

  defp public_pool_exhausted_details(nil), do: %{}

  defp maybe_put_resets_at(error, %DateTime{} = retry_at),
    do: Map.put(error, :resets_at, DateTime.to_unix(retry_at))

  defp maybe_put_resets_at(error, nil), do: error
end
