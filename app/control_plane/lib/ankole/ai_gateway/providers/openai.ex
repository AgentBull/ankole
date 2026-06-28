defmodule Ankole.AIGateway.Providers.OpenAI do
  @moduledoc """
  Provider implementation for first-party OpenAI.

  OpenAI defaults to the Responses API, but keeps a Chat Completions mode for
  models or deployments that still require that wire contract.
  """

  @behaviour Ankole.AIGateway.Provider

  alias Ankole.AIGateway.Providers.OpenAICompatible

  @impl true
  def provider_id, do: "openai"

  @impl true
  def label, do: "OpenAI"

  @impl true
  def capabilities, do: ["llm"]

  @impl true
  def endpoint_modes, do: ["responses", "chat_completions"]

  @impl true
  def provider_strategy, do: "openai_responses"

  @impl true
  def default_base_url, do: "https://api.openai.com/v1"

  @impl true
  def default_http_protocol, do: "http2"

  @impl true
  def credential_schemes, do: ["api_key", "bearer"]

  @impl true
  def connection_option_keys,
    do:
      ~w(http_protocol endpoint_kind organization project headers query_params include_usage supports_structured_outputs)

  @impl true
  def runtime_provider_option_keys,
    do:
      ~w(reasoningEffort reasoningSummary promptCacheKey promptCacheRetention serviceTier strictJsonSchema textVerbosity truncation systemMessageMode forceReasoning contextManagement allowedTools)

  @impl true
  def model_catalog_policy, do: "known_or_provider_specific"

  @impl true
  def response_endpoint_mode(%{"connection_options" => options}) do
    case Map.get(options, "endpoint_kind") do
      "chat_completions" -> "chat_completions"
      "compatible" -> "chat_completions"
      _kind -> "responses"
    end
  end

  def response_endpoint_mode(_runtime), do: "responses"

  @impl true
  def build_response_request(runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, request} <-
           Ankole.AIGateway.Request.build_openai_compatible_response_request(
             runtime,
             request,
             response_endpoint_mode(runtime),
             stream?: stream?
           ) do
      {:ok, maybe_stream_request(request, stream?)}
    end
  end

  @impl true
  def normalize_response_body(runtime, upstream_request, upstream_response),
    do: OpenAICompatible.normalize_response_body(runtime, upstream_request, upstream_response)

  @impl true
  def put_headers(headers, %{"connection_options" => options}) do
    headers
    |> maybe_put_header("openai-organization", Map.get(options, "organization"))
    |> maybe_put_header("openai-project", Map.get(options, "project"))
  end

  def put_headers(headers, _runtime), do: headers

  @impl true
  def put_auth_headers(headers, runtime), do: OpenAICompatible.put_auth_headers(headers, runtime)

  @impl true
  def stream_init(runtime, upstream_request),
    do: OpenAICompatible.stream_init(runtime, upstream_request)

  @impl true
  def decode_stream_message(runtime, upstream_request, state, message),
    do: OpenAICompatible.decode_stream_message(runtime, upstream_request, state, message)

  @impl true
  def finish_stream(runtime, upstream_request, state),
    do: OpenAICompatible.finish_stream(runtime, upstream_request, state)

  defp maybe_stream_request(request, false), do: request

  defp maybe_stream_request(request, true) do
    request
    |> put_in([:headers, "accept"], "text/event-stream")
    |> Map.put(:stream?, true)
  end

  defp maybe_put_header(headers, _name, nil), do: headers
  defp maybe_put_header(headers, _name, ""), do: headers
  defp maybe_put_header(headers, name, value), do: Map.put(headers, name, to_string(value))
end
