defmodule AnkoleWeb.AIGatewayController do
  @moduledoc """
  Agent-authenticated AIGateway runtime API.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.AIGateway
  alias OpenApiSpex.Schema

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

    case AIGateway.stream_requested?(request) do
      true ->
        stream_response(conn, subject_uid, request)

      false ->
        case AIGateway.create_response(subject_uid, request) do
          {:ok, %{body: body}} -> json(conn, body)
          {:error, reason} -> error(conn, reason)
        end
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

    {:ok, body} = AIGateway.list_models(subject_uid, subject_type, params)
    json(conn, body)
  end

  defp stream_response(conn, subject_uid, request) do
    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    case AIGateway.stream_response(subject_uid, request, conn, &sse_emit/2, []) do
      {:ok, _response, conn} ->
        chunk_or_keep(conn, "data: [DONE]\n\n")

      {:error, reason} ->
        event = stream_error_event(reason)
        conn = chunk_or_keep(conn, sse_chunk(event))
        chunk_or_keep(conn, "data: [DONE]\n\n")
    end
  end

  defp sse_emit(event, conn) do
    case Plug.Conn.chunk(conn, sse_chunk(event)) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunk_or_keep(conn, chunk) do
    case Plug.Conn.chunk(conn, chunk) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp sse_chunk(%{"type" => type} = event) do
    "event: #{type}\ndata: #{Ankole.JSON.encode!(event)}\n\n"
  end

  defp stream_error_event(reason) do
    {_status, code, message} = error_tuple(reason)

    %{
      "type" => "error",
      "error" => %{
        "type" => "invalid_request_error",
        "code" => code,
        "message" => message,
        "param" => nil
      }
    }
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

  defp error_tuple(:invalid_embedding_input),
    do: {400, "invalid_embedding_input", "input must be text, token arrays, or input blocks"}

  defp error_tuple(:invalid_documents),
    do: {400, "invalid_documents", "documents must be a non-empty array"}

  defp error_tuple(:invalid_top_n), do: {400, "invalid_top_n", "top_n must be a positive integer"}

  defp error_tuple(:invalid_request_body),
    do: {400, "invalid_request_body", "JSON object body required"}

  defp error_tuple(:credential_missing),
    do: {422, "credential_missing", "provider credential is missing"}

  defp error_tuple(:provider_disabled), do: {422, "provider_disabled", "provider is disabled"}
  defp error_tuple(:not_found), do: {404, "not_found", "resource not found"}
  defp error_tuple(:agent_not_found), do: {404, "agent_not_found", "agent not found"}

  defp error_tuple({:unknown_model_selector, _capability, selector}),
    do: {422, "unknown_model_selector", "unknown model selector: #{selector}"}

  defp error_tuple({:model_binding_not_configured, capability, name}),
    do: {422, "model_binding_not_configured", "#{capability}.#{name} is not configured"}

  defp error_tuple({:unsupported_capability, capability}),
    do: {422, "unsupported_capability", "provider does not support #{capability}"}

  defp error_tuple({:upstream_request_failed, reason}),
    do: {502, "upstream_request_failed", inspect(reason)}

  defp error_tuple({:upstream_response_failed, status, body}) when is_integer(status),
    do:
      {upstream_public_status(status), "upstream_response_failed",
       upstream_error_message(status, body)}

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
end
