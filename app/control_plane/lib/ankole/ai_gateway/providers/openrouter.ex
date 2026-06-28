defmodule Ankole.AIGateway.Providers.OpenRouter do
  @moduledoc """
  Provider implementation for OpenRouter.

  OpenRouter is modeled as an OpenAI-compatible provider with provider-owned
  defaults: a concrete base URL, HTTP/2, attribution headers, LLM dispatch via
  Chat Completions, and first-class embedding/rerank endpoints.
  """

  @behaviour Ankole.AIGateway.Provider

  alias Ankole.AIGateway.Embeddings
  alias Ankole.AIGateway.Providers.OpenAICompatible
  alias Ankole.AIGateway.Request
  alias Ankole.AIGateway.Rerank

  @default_referer "https://github.com/agentbull/ankole"
  @default_title "Ankole"

  @impl true
  def provider_id, do: "openrouter"

  @impl true
  def label, do: "OpenRouter"

  @impl true
  def capabilities, do: ["llm", "embedding", "rerank"]

  @impl true
  def endpoint_modes, do: ["chat_completions", "embeddings", "rerank"]

  @impl true
  def provider_strategy, do: "openai_compatible_chat_completions"

  @impl true
  def default_base_url, do: "https://openrouter.ai/api/v1"

  @impl true
  def default_http_protocol, do: "http2"

  @impl true
  def credential_schemes, do: ["api_key", "bearer"]

  @impl true
  def connection_option_keys,
    do:
      ~w(http_protocol headers query_params include_usage supports_structured_outputs app_referer app_title referer title)

  @impl true
  def runtime_provider_option_keys,
    do: ~w(user reasoning reasoningEffort textVerbosity strictJsonSchema)

  @impl true
  def model_catalog_policy, do: "provider_specific"

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
  def build_embeddings_request(runtime, request),
    do:
      Request.build_json_request(runtime, "embeddings", request,
        inject_model?: true,
        merge_provider_options?: true
      )

  @impl true
  def normalize_embeddings_body(runtime, _upstream_request, upstream_response),
    do: Embeddings.normalize_body(runtime, upstream_response)

  @impl true
  def build_rerank_request(runtime, request),
    do:
      Request.build_json_request(runtime, "rerank", request,
        inject_model?: true,
        merge_provider_options?: true
      )

  @impl true
  def normalize_rerank_body(runtime, upstream_request, upstream_response),
    do: Rerank.normalize_body(runtime, upstream_request.body, upstream_response)

  @impl true
  def put_headers(headers, %{"connection_options" => options}) do
    # OpenRouter uses attribution headers for app identity. Defaults keep local
    # setup usable, while connection options allow operator branding later.
    referer = Map.get(options, "app_referer") || Map.get(options, "referer") || @default_referer
    title = Map.get(options, "app_title") || Map.get(options, "title") || @default_title

    headers
    |> Map.put_new("HTTP-Referer", referer)
    |> Map.put_new("X-Title", title)
    |> Map.put_new("X-OpenRouter-Title", title)
  end

  def put_headers(headers, _runtime), do: put_headers(headers, %{"connection_options" => %{}})

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
