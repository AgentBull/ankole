defmodule Ankole.AIGateway.Providers do
  @moduledoc """
  Provider registry and runtime dispatcher for AIGateway.

  Provider modules are the source of truth for metadata and behavior. This
  registry mirrors the req_llm/BullX shape: discover provider modules, validate
  their declarations, expose operator-facing metadata, and dispatch runtime
  calls back to the owning provider module.
  """

  alias Ankole.AIGateway.HttpProtocol
  alias Ankole.Plugins

  @contract_id "ai_gateway.provider"

  # Header names an operator is forbidden from setting in `connection_options`.
  # Credentials must flow through the sealed provider credential column, not
  # plaintext connection headers, so any header that could smuggle a secret is
  # rejected at validation time.
  @secret_header_names MapSet.new([
                         "authorization",
                         "proxy-authorization",
                         "x-api-key",
                         "api-key",
                         "apikey",
                         "openai-api-key",
                         "anthropic-api-key",
                         "x-goog-api-key",
                         "cookie",
                         "set-cookie"
                       ])

  @builtins [
    Ankole.AIGateway.Providers.AzureOpenAI,
    Ankole.AIGateway.Providers.Claude,
    Ankole.AIGateway.Providers.OpenAI,
    Ankole.AIGateway.Providers.OpenAICompatible,
    Ankole.AIGateway.Providers.OpenRouter,
    Ankole.AIGateway.Providers.GoogleAIStudioOpenAI,
    Ankole.AIGateway.Providers.Jina
  ]

  defmodule Definition do
    @moduledoc """
    Static provider metadata derived from one provider implementation module.
    """

    @enforce_keys [
      :provider_kind,
      :label,
      :module,
      :capabilities,
      :endpoint_modes,
      :provider_strategy,
      :default_base_url,
      :default_http_protocol,
      :credential_modes,
      :connection_option_keys,
      :runtime_provider_option_keys,
      :model_catalog_policy
    ]
    defstruct [
      :provider_kind,
      :label,
      :module,
      :capabilities,
      :endpoint_modes,
      :provider_strategy,
      :default_base_url,
      :default_http_protocol,
      :credential_modes,
      :connection_option_keys,
      :runtime_provider_option_keys,
      :model_catalog_policy
    ]

    @type t :: %__MODULE__{
            provider_kind: String.t(),
            label: String.t(),
            module: module(),
            capabilities: [String.t()],
            endpoint_modes: [String.t()],
            provider_strategy: String.t(),
            default_base_url: String.t() | nil,
            default_http_protocol: String.t(),
            credential_modes: [String.t()],
            connection_option_keys: [String.t()],
            runtime_provider_option_keys: [String.t()],
            model_catalog_policy: String.t()
          }
  end

  @doc """
  Lists built-in and active plugin provider implementations.
  """
  @spec all() :: [Definition.t()]
  def all do
    plugin_modules =
      @contract_id
      |> Plugins.adapter_declarations()
      |> Enum.flat_map(fn declaration ->
        case declaration_module(declaration) do
          {:ok, module} -> [module]
          {:error, _reason} -> []
        end
      end)

    (@builtins ++ plugin_modules)
    |> Enum.map(&definition!/1)
    |> Enum.uniq_by(& &1.provider_kind)
  end

  @doc """
  Lists provider implementation ids.
  """
  @spec list() :: [String.t()]
  def list do
    all()
    |> Enum.map(& &1.provider_kind)
    |> Enum.sort()
  end

  @doc """
  Fetches one provider implementation definition by kind.
  """
  @spec fetch(String.t()) :: {:ok, Definition.t()} | {:error, :unknown_ai_gateway_provider}
  def fetch(provider_kind) when is_binary(provider_kind) do
    normalized = normalize_id(provider_kind)

    case Enum.find(all(), &(&1.provider_kind == normalized)) do
      %Definition{} = provider -> {:ok, provider}
      nil -> {:error, :unknown_ai_gateway_provider}
    end
  end

  def fetch(_provider_kind), do: {:error, :unknown_ai_gateway_provider}

  @doc """
  Projects provider metadata for Console/OpenAPI use.
  """
  @spec projection(Definition.t()) :: map()
  def projection(%Definition{} = provider) do
    %{
      "provider_kind" => provider.provider_kind,
      "label" => provider.label,
      "capabilities" => provider.capabilities,
      "endpoint_modes" => provider.endpoint_modes,
      "provider_strategy" => provider.provider_strategy,
      "default_base_url" => provider.default_base_url,
      "default_http_protocol" => provider.default_http_protocol,
      "credential_modes" => provider.credential_modes,
      "connection_options" => provider.connection_option_keys,
      "runtime_provider_options" => provider.runtime_provider_option_keys,
      "model_catalog_policy" => provider.model_catalog_policy
    }
  end

  @doc """
  Validates and normalizes provider connection options for one provider kind.
  """
  @spec normalize_connection_options(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_connection_options(provider_kind, options) when is_map(options) do
    options = normalize_option_keys(options)

    with {:ok, provider} <- fetch(provider_kind),
         :ok <- reject_unknown_keys(options, provider.connection_option_keys, :connection_options),
         :ok <- validate_headers(Map.get(options, "headers")),
         :ok <- validate_query_params(Map.get(options, "query_params")),
         :ok <- HttpProtocol.validate_optional(Map.get(options, "http_protocol")),
         :ok <- validate_endpoint_kind(provider, Map.get(options, "endpoint_kind")),
         :ok <- validate_auth_mode(provider, Map.get(options, "auth_mode")),
         :ok <- validate_auth_scheme(provider, Map.get(options, "auth_scheme")) do
      {:ok, options}
    end
  end

  def normalize_connection_options(_provider_kind, _options),
    do: {:error, :invalid_connection_options}

  @doc """
  Validates provider-specific per-call options stored on an agent profile.
  """
  @spec validate_runtime_provider_options(String.t(), map()) :: :ok | {:error, term()}
  def validate_runtime_provider_options(provider_kind, options) when is_map(options) do
    with {:ok, provider} <- fetch(provider_kind) do
      reject_unknown_keys(options, provider.runtime_provider_option_keys, :provider_options)
    end
  end

  def validate_runtime_provider_options(_provider_kind, _options),
    do: {:error, :invalid_provider_options}

  @doc """
  Validates that a credential mode is accepted by the provider implementation.
  """
  @spec validate_credential_mode(String.t(), String.t()) :: :ok | {:error, term()}
  def validate_credential_mode(provider_kind, mode) when is_binary(mode) do
    with {:ok, provider} <- fetch(provider_kind) do
      case mode in provider.credential_modes do
        true -> :ok
        false -> {:error, :unsupported_credential_mode}
      end
    end
  end

  def validate_credential_mode(_provider_kind, _mode), do: {:error, :unsupported_credential_mode}

  @doc """
  Returns true when the provider implementation supports a capability kind.
  """
  @spec supports_capability?(Definition.t(), String.t()) :: boolean()
  def supports_capability?(%Definition{} = provider, capability),
    do: capability in provider.capabilities

  @doc """
  Builds a registry definition from a provider implementation module.

  The provider module remains the source of truth; this function only projects
  callback values into a struct used by the registry and API.
  """
  @spec definition!(module()) :: Definition.t()
  def definition!(module) when is_atom(module) do
    %Definition{
      provider_kind: normalize_id(module.provider_id()),
      label: module.label(),
      module: module,
      capabilities: module.capabilities(),
      endpoint_modes: module.endpoint_modes(),
      provider_strategy: module.provider_strategy(),
      default_base_url: module.default_base_url(),
      default_http_protocol: module.default_http_protocol(),
      credential_modes: module.credential_schemes(),
      connection_option_keys: module.connection_option_keys(),
      runtime_provider_option_keys: module.runtime_provider_option_keys(),
      model_catalog_policy: module.model_catalog_policy()
    }
  end

  @doc """
  Returns the provider module that owns the resolved runtime map.
  """
  @spec module_for_runtime(map()) :: {:ok, module()} | {:error, :unknown_ai_gateway_provider}
  def module_for_runtime(%{"provider_kind" => provider_kind}), do: module_for_kind(provider_kind)
  def module_for_runtime(_runtime), do: {:error, :unknown_ai_gateway_provider}

  @doc """
  Checks that a provider kind can serve the requested AIGateway capability.
  """
  @spec ensure_capability_supported(Definition.t(), String.t()) ::
          :ok | {:error, {:unsupported_capability, String.t()}}
  def ensure_capability_supported(%Definition{} = provider, capability) do
    case supports_capability?(provider, capability) do
      true -> :ok
      false -> {:error, {:unsupported_capability, capability}}
    end
  end

  @doc """
  Returns the upstream response endpoint mode selected for a runtime call.
  """
  @spec response_endpoint_mode(map()) :: String.t()
  def response_endpoint_mode(runtime) when is_map(runtime) do
    case module_for_runtime(runtime) do
      {:ok, module} -> module.response_endpoint_mode(runtime)
      {:error, _reason} -> "chat_completions"
    end
  end

  @doc """
  Returns the single Finch HTTP protocol selected for a runtime call.

  This is intentionally not adaptive. Mixed HTTP/1 and HTTP/2 pools can fail in
  Finch for large HTTP/2 bodies, so each provider call chooses one protocol.
  """
  @spec http_protocol(map()) :: String.t()
  def http_protocol(%{"connection_options" => %{"http_protocol" => protocol}})
      when protocol in ["http1", "http2"],
      do: protocol

  def http_protocol(runtime) when is_map(runtime) do
    case module_for_runtime(runtime) do
      {:ok, module} -> module.default_http_protocol()
      {:error, _reason} -> "http1"
    end
  end

  @doc """
  Delegates `/responses` request construction to the selected provider module.
  """
  @spec build_response_request(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_response_request(runtime, request, opts \\ []) do
    with {:ok, module} <- module_for_runtime(runtime) do
      module.build_response_request(runtime, request, opts)
    end
  end

  @doc """
  Delegates `/responses` body normalization to the selected provider module.
  """
  @spec normalize_response_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_response_body(runtime, upstream_request, upstream_response) do
    with {:ok, module} <- module_for_runtime(runtime) do
      module.normalize_response_body(runtime, upstream_request, upstream_response)
    end
  end

  @doc """
  Delegates `/embeddings` request construction when the provider supports it.
  """
  @spec build_embeddings_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_embeddings_request(runtime, request) do
    with {:ok, module} <- module_for_runtime(runtime),
         true <- function_exported?(module, :build_embeddings_request, 2) do
      apply(module, :build_embeddings_request, [runtime, request])
    else
      false -> {:error, {:unsupported_capability, "embedding"}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Delegates `/embeddings` body normalization when the provider supports it.
  """
  @spec normalize_embeddings_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_embeddings_body(runtime, upstream_request, upstream_response) do
    with {:ok, module} <- module_for_runtime(runtime),
         true <- function_exported?(module, :normalize_embeddings_body, 3) do
      apply(module, :normalize_embeddings_body, [runtime, upstream_request, upstream_response])
    else
      false -> {:error, {:unsupported_capability, "embedding"}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Delegates `/rerank` request construction when the provider supports it.
  """
  @spec build_rerank_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_rerank_request(runtime, request) do
    with {:ok, module} <- module_for_runtime(runtime),
         true <- function_exported?(module, :build_rerank_request, 2) do
      apply(module, :build_rerank_request, [runtime, request])
    else
      false -> {:error, {:unsupported_capability, "rerank"}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Delegates `/rerank` body normalization when the provider supports it.
  """
  @spec normalize_rerank_body(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_rerank_body(runtime, upstream_request, upstream_response) do
    with {:ok, module} <- module_for_runtime(runtime),
         true <- function_exported?(module, :normalize_rerank_body, 3) do
      apply(module, :normalize_rerank_body, [runtime, upstream_request, upstream_response])
    else
      false -> {:error, {:unsupported_capability, "rerank"}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Builds outbound headers for one resolved provider runtime.

  Operator headers are applied first, then provider defaults and auth headers.
  Secret-bearing header names are rejected during provider-row validation, so
  credentials can only enter here through the sealed credential field.
  """
  @spec request_headers(map()) :: {:ok, map()}
  def request_headers(runtime) when is_map(runtime) do
    with {:ok, module} <- module_for_runtime(runtime) do
      headers =
        runtime
        |> connection_headers()
        |> module.put_headers(runtime)
        |> module.put_auth_headers(runtime)
        |> Map.put("content-type", "application/json")
        |> Map.put("accept", accept_header(runtime))

      {:ok, headers}
    end
  end

  # The plugin registry still exposes generic adapter declarations because other
  # plugin contracts use the same mechanism. AIGateway only accepts declarations
  # under the `ai_gateway.provider` contract and treats the module as a provider.
  defp declaration_module(%{"module" => module}) when is_atom(module), do: {:ok, module}
  defp declaration_module(%{module: module}) when is_atom(module), do: {:ok, module}

  defp declaration_module(%{"module" => module}) when is_binary(module), do: safe_module(module)
  defp declaration_module(%{module: module}) when is_binary(module), do: safe_module(module)
  defp declaration_module(_declaration), do: {:error, :missing_provider_module}

  defp safe_module(module) do
    {:ok, Module.safe_concat([module])}
  rescue
    _error -> {:error, :invalid_provider_module}
  end

  defp module_for_kind(provider_kind) when is_binary(provider_kind) do
    with {:ok, %Definition{module: module}} <- fetch(provider_kind) do
      {:ok, module}
    end
  end

  defp module_for_kind(_provider_kind), do: {:error, :unknown_ai_gateway_provider}

  defp connection_headers(%{"connection_options" => %{"headers" => headers}})
       when is_map(headers) do
    Map.new(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp connection_headers(_runtime), do: %{}

  defp accept_header(%{"stream" => true}), do: "text/event-stream"
  defp accept_header(_runtime), do: "application/json"

  defp normalize_id(value) when is_binary(value), do: value |> String.trim() |> String.downcase()

  defp normalize_option_keys(options) do
    Map.new(options, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp reject_unknown_keys(options, allowed, error_tag) do
    allowed = MapSet.new(allowed)

    options
    |> normalize_option_keys()
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> case do
      [] -> :ok
      keys -> {:error, {error_tag, {:unknown_keys, Enum.sort(keys)}}}
    end
  end

  defp validate_headers(nil), do: :ok

  defp validate_headers(headers) when is_map(headers) do
    headers
    |> Enum.reduce_while(:ok, fn
      {name, value}, :ok when is_binary(name) and is_binary(value) ->
        case MapSet.member?(@secret_header_names, String.downcase(name)) do
          true -> {:halt, {:error, {:secret_header, name}}}
          false -> {:cont, :ok}
        end

      _header, :ok ->
        {:halt, {:error, :invalid_headers}}
    end)
  end

  defp validate_headers(_headers), do: {:error, :invalid_headers}

  defp validate_query_params(nil), do: :ok

  defp validate_query_params(params) when is_map(params) do
    case Enum.all?(params, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      true -> :ok
      false -> {:error, :invalid_query_params}
    end
  end

  defp validate_query_params(_params), do: {:error, :invalid_query_params}

  defp validate_endpoint_kind(_provider, nil), do: :ok

  defp validate_endpoint_kind(%Definition{endpoint_modes: modes}, kind) when is_binary(kind) do
    # `official` and `compatible` are old operator words that map to concrete
    # provider choices elsewhere. They are accepted as selectors, not persisted
    # as extra endpoint modes on providers.
    case kind in modes or kind in ["official", "compatible"] do
      true -> :ok
      false -> {:error, :invalid_endpoint_kind}
    end
  end

  defp validate_endpoint_kind(_provider, _kind), do: {:error, :invalid_endpoint_kind}

  defp validate_auth_mode(provider, mode), do: validate_auth_selector(provider, mode, "auth_mode")

  defp validate_auth_scheme(provider, mode),
    do: validate_auth_selector(provider, mode, "auth_scheme")

  defp validate_auth_selector(_provider, nil, _field), do: :ok

  defp validate_auth_selector(%Definition{credential_modes: modes}, mode, _field)
       when is_binary(mode) do
    case mode in modes do
      true -> :ok
      false -> {:error, :invalid_credential_mode}
    end
  end

  defp validate_auth_selector(_provider, _mode, field),
    do: {:error, {:invalid_auth_selector, field}}
end
