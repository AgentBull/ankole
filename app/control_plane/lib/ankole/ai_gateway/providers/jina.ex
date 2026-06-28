defmodule Ankole.AIGateway.Providers.Jina do
  @moduledoc """
  Provider implementation for Jina embedding and rerank APIs.

  Jina is not an LLM provider in v1. It participates in the same provider
  registry so embeddings and rerank share credential storage, model resolution,
  and HTTP transport with LLM providers.
  """

  @behaviour Ankole.AIGateway.Provider

  alias Ankole.AIGateway.Embeddings
  alias Ankole.AIGateway.Providers.OpenAICompatible
  alias Ankole.AIGateway.Request
  alias Ankole.AIGateway.Rerank

  @impl true
  def provider_id, do: "jina"

  @impl true
  def label, do: "Jina AI"

  @impl true
  def capabilities, do: ["embedding", "rerank"]

  @impl true
  def endpoint_modes, do: ["embeddings", "rerank"]

  @impl true
  def provider_strategy, do: "embedding_rerank"

  @impl true
  def default_base_url, do: "https://api.jina.ai/v1"

  @impl true
  def default_http_protocol, do: "http2"

  @impl true
  def credential_schemes, do: ["api_key", "bearer"]

  @impl true
  def connection_option_keys, do: ~w(http_protocol headers query_params)

  @impl true
  def runtime_provider_option_keys,
    do:
      ~w(embedding_type task dimensions normalized late_chunking truncate return_multivector return_documents top_n)

  @impl true
  def model_catalog_policy, do: "provider_specific"

  @impl true
  def response_endpoint_mode(_runtime), do: "unsupported"

  @impl true
  def build_response_request(_runtime, _request, _opts),
    do: {:error, {:unsupported_capability, "llm"}}

  @impl true
  def normalize_response_body(_runtime, _upstream_request, _upstream_response),
    do: {:error, {:unsupported_capability, "llm"}}

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
  def put_headers(headers, _runtime), do: headers

  @impl true
  def put_auth_headers(headers, runtime), do: OpenAICompatible.put_auth_headers(headers, runtime)
end
