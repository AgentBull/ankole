defmodule Ankole.AIGateway.Providers.GoogleAIStudioOpenAI do
  @moduledoc """
  Provider implementation for Google AI Studio's OpenAI-compatible endpoint.

  This provider uses Google's documented `/v1beta/openai` compatibility surface.
  It is separate from a future native Gemini provider because the native Gemini
  API has different request, stream, and auth details.
  """

  @behaviour Ankole.AIGateway.Provider

  alias Ankole.AIGateway.Providers.OpenAICompatible
  alias Ankole.AIGateway.Request

  @impl true
  def provider_id, do: "google_ai_studio_openai"

  @impl true
  def label, do: "Google AI Studio OpenAI Compatibility"

  @impl true
  def capabilities, do: ["llm"]

  @impl true
  def endpoint_modes, do: ["chat_completions"]

  @impl true
  def provider_strategy, do: "openai_compatible_chat_completions"

  @impl true
  def default_base_url, do: "https://generativelanguage.googleapis.com/v1beta/openai"

  @impl true
  def default_http_protocol, do: "http2"

  @impl true
  def credential_schemes, do: ["api_key", "bearer"]

  @impl true
  def connection_option_keys, do: ~w(http_protocol headers query_params)

  @impl true
  def runtime_provider_option_keys, do: ~w(user reasoningEffort textVerbosity strictJsonSchema)

  @impl true
  def model_catalog_policy, do: "known_or_custom"

  @impl true
  def response_endpoint_mode(_runtime), do: "chat_completions"

  @impl true
  def build_response_request(runtime, request, opts) do
    stream? = Keyword.get(opts, :stream?, false)

    with {:ok, request} <-
           Request.build_openai_compatible_response_request(
             runtime,
             request,
             "chat_completions",
             stream?: stream?
           ) do
      {:ok, maybe_stream_request(request, stream?)}
    end
  end

  @impl true
  def normalize_response_body(runtime, upstream_request, upstream_response),
    do: OpenAICompatible.normalize_response_body(runtime, upstream_request, upstream_response)

  @impl true
  def put_headers(headers, _runtime),
    do: Map.put_new(headers, "x-goog-api-client", "ankole-ai-gateway/0.1")

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
end
