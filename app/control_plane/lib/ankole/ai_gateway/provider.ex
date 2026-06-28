defmodule Ankole.AIGateway.Provider do
  @moduledoc """
  Behaviour for AIGateway provider implementations.

  A provider owns the impedance with one upstream API family: endpoint URLs,
  authentication headers, request body conversion, non-stream response
  normalization, and upstream SSE event decoding into the AIGateway public
  contract. This mirrors the req_llm provider boundary, but the request and
  response shapes here are Ankole's control-plane gateway contracts.
  """

  @doc "Returns the stable provider kind id stored by provider rows and model bindings."
  @callback provider_id() :: String.t()
  @doc "Returns the operator-facing display label for Console metadata."
  @callback label() :: String.t()
  @doc "Returns the AIGateway capability kinds implemented by this provider."
  @callback capabilities() :: [String.t()]
  @doc "Returns the upstream endpoint modes that this provider can speak."
  @callback endpoint_modes() :: [String.t()]
  @doc "Returns a coarse implementation strategy used for metadata and debugging."
  @callback provider_strategy() :: String.t()
  @doc "Returns the default upstream base URL, or nil when an operator must supply one."
  @callback default_base_url() :: String.t() | nil
  @doc "Returns the default Finch protocol selection: `http1` or `http2`."
  @callback default_http_protocol() :: String.t()
  @doc "Returns accepted credential presentation modes for this provider."
  @callback credential_schemes() :: [String.t()]
  @doc "Returns connection option keys accepted by this provider."
  @callback connection_option_keys() :: [String.t()]
  @doc "Returns per-call provider option keys accepted by this provider."
  @callback runtime_provider_option_keys() :: [String.t()]
  @doc "Returns how model catalog entries should be treated for this provider."
  @callback model_catalog_policy() :: String.t()

  @doc "Returns the upstream response endpoint mode selected for a runtime call."
  @callback response_endpoint_mode(map()) :: String.t()

  @doc "Builds the provider-facing request for an AIGateway `/responses` call."
  @callback build_response_request(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @doc "Normalizes a provider response body into the AIGateway Responses contract."
  @callback normalize_response_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}

  @doc "Builds the provider-facing request for an AIGateway `/embeddings` call."
  @callback build_embeddings_request(map(), map()) :: {:ok, map()} | {:error, term()}
  @doc "Normalizes a provider embedding body into the AIGateway embedding contract."
  @callback normalize_embeddings_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}

  @doc "Builds the provider-facing request for an AIGateway `/rerank` call."
  @callback build_rerank_request(map(), map()) :: {:ok, map()} | {:error, term()}
  @doc "Normalizes a provider rerank body into the AIGateway rerank contract."
  @callback normalize_rerank_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}

  @doc "Adds provider-specific non-secret headers to an outbound request."
  @callback put_headers(map(), map()) :: map()
  @doc "Adds credential-bearing auth headers from the sealed runtime credential."
  @callback put_auth_headers(map(), map()) :: map()

  @doc "Initializes provider-owned state for upstream SSE decoding."
  @callback stream_init(map(), map()) :: map()
  @doc "Converts one parsed upstream SSE message into normalized Responses events."
  @callback decode_stream_message(map(), map(), map(), map() | :done) ::
              {:ok, [map()], map()} | {:error, term()}
  @doc "Finalizes stream state when the upstream connection ends."
  @callback finish_stream(map(), map(), map()) :: {:ok, [map()], map()} | {:error, term()}

  @optional_callbacks build_embeddings_request: 2,
                      normalize_embeddings_body: 3,
                      build_rerank_request: 2,
                      normalize_rerank_body: 3,
                      stream_init: 2,
                      decode_stream_message: 4,
                      finish_stream: 3
end
