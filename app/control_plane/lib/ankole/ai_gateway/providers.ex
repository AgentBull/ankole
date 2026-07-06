defmodule Ankole.AIGateway.Providers do
  @moduledoc """
  Provider registry and request dispatcher for AIGateway.

  Provider modules expose a compiled `ProviderDefinition`. Runtime request
  dispatch creates a `PrepareContext`, calls the capability's provider-owned
  prepare function, and hands the resulting prepared request to the native
  UniversalAIClient path.
  """

  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.ProviderDefinition
  alias Ankole.AIGateway.ProviderDefinition.Capability
  alias Ankole.AIGateway.ProviderDefinition.Setting
  alias Ankole.AIGateway.UniversalAIRequest
  alias Ankole.Plugins

  @contract_id "ai_gateway.provider"
  @common_connection_settings ~w(base_url headers query_params transport)
  @cache_key {__MODULE__, :registry}

  @builtins [
    Ankole.AIGateway.Providers.AzureOpenAI,
    Ankole.AIGateway.Providers.Claude,
    Ankole.AIGateway.Providers.OpenAI,
    Ankole.AIGateway.Providers.OpenAICompatible,
    Ankole.AIGateway.Providers.OpenRouter,
    Ankole.AIGateway.Providers.GoogleAIStudioOpenAI,
    Ankole.AIGateway.Providers.Jina,
    Ankole.AIGateway.Providers.Parallel,
    Ankole.AIGateway.Providers.BrightDataSERP,
    Ankole.AIGateway.Providers.AgentBullCloud,
    Ankole.AIGateway.Providers.JinaSearch,
    Ankole.AIGateway.Providers.JinaReader
  ]

  @type definition :: ProviderDefinition.t()

  @doc """
  Lists built-in and active plugin provider definitions.

  Invalid plugin declarations are skipped instead of crashing the registry so a
  bad plugin cannot hide every built-in provider from Console or runtime paths.
  """
  @spec all() :: [definition()]
  def all do
    registry().definitions
  end

  @doc """
  Rebuilds the provider registry cache from the active plugin registry.
  """
  @spec refresh() :: %{definitions: [definition()], by_kind: %{String.t() => definition()}}
  def refresh do
    declarations =
      case Process.whereis(Ankole.Plugins.Registry) do
        nil -> []
        _pid -> Plugins.adapter_declarations(@contract_id)
      end

    refresh_from_adapter_declarations(declarations)
  end

  @doc false
  @spec refresh_from_adapter_declarations([map()]) :: %{
          definitions: [definition()],
          by_kind: %{String.t() => definition()}
        }
  def refresh_from_adapter_declarations(declarations) when is_list(declarations) do
    registry = build_registry(declarations)
    :persistent_term.put(@cache_key, registry)
    registry
  end

  @doc false
  def reset_for_test do
    :persistent_term.erase(@cache_key)
    :ok
  end

  @doc """
  Lists provider kind ids in stable sorted order.
  """
  @spec list() :: [String.t()]
  def list do
    all()
    |> Enum.map(& &1.provider_kind)
    |> Enum.sort()
  end

  @doc """
  Fetches one provider definition by provider kind.
  """
  @spec fetch(String.t()) :: {:ok, definition()} | {:error, :unknown_ai_gateway_provider}
  def fetch(provider_kind) when is_binary(provider_kind) do
    normalized = normalize_id(provider_kind)

    case Map.get(registry().by_kind, normalized) do
      %ProviderDefinition{} = provider -> {:ok, provider}
      nil -> {:error, :unknown_ai_gateway_provider}
    end
  end

  def fetch(_provider_kind), do: {:error, :unknown_ai_gateway_provider}

  @doc """
  Projects a provider definition for Console and public metadata APIs.

  The projection exposes accepted option keys and capability specs, but never
  includes decrypted option values. Runtime request construction gets those from
  `ProviderConfigs.runtime_connection/1` instead.
  """
  @spec projection(definition()) :: map()
  def projection(%ProviderDefinition{} = provider) do
    %{
      "provider_kind" => provider.provider_kind,
      "label" => stringify_label(provider.label),
      "capabilities" => capability_names(provider),
      "settings" => Enum.map(provider.settings, &setting_projection/1),
      "capability_specs" => Enum.map(provider.capabilities, &capability_projection/1),
      "default_base_url" => provider.base_url,
      "connection_options" => connection_option_keys(provider),
      "runtime_provider_options" => runtime_provider_option_keys(provider)
    }
  end

  @doc """
  Normalizes and validates stored connection options for a provider kind.

  The allowed keys come from provider settings plus common transport/request
  fields. This catches typos at provider-config write time without adding a
  global provider schema.
  """
  @spec normalize_connection_options(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_connection_options(provider_kind, options) when is_map(options) do
    options = normalize_option_keys(options)

    with {:ok, provider} <- fetch(provider_kind),
         :ok <-
           reject_unknown_keys(options, connection_option_keys(provider), :connection_options) do
      {:ok, options}
    end
  end

  def normalize_connection_options(_provider_kind, _options),
    do: {:error, :invalid_connection_options}

  @doc """
  Validates per-request provider options for a provider kind.
  """
  @spec validate_runtime_provider_options(String.t(), map()) :: :ok | {:error, term()}
  def validate_runtime_provider_options(provider_kind, options) when is_map(options) do
    with {:ok, provider} <- fetch(provider_kind) do
      reject_unknown_keys(options, runtime_provider_option_keys(provider), :provider_options)
    end
  end

  def validate_runtime_provider_options(_provider_kind, _options),
    do: {:error, :invalid_provider_options}

  @doc """
  Returns whether a provider definition supports a public capability name.
  """
  @spec supports_capability?(definition(), String.t()) :: boolean()
  def supports_capability?(%ProviderDefinition{} = provider, capability),
    do: capability in capability_names(provider)

  @doc """
  Loads and validates a provider module's compiled definition.

  This intentionally raises for built-in modules because a bad built-in
  declaration is a boot-time coding error, not a runtime user error.
  """
  @spec definition!(module()) :: definition()
  def definition!(module) when is_atom(module) do
    case module.provider_definition() do
      %ProviderDefinition{} = definition ->
        definition

      other ->
        raise ArgumentError,
              "#{inspect(module)} returned invalid provider definition: #{inspect(other)}"
    end
  end

  @doc """
  Checks that a provider can serve the requested public capability.
  """
  @spec ensure_capability_supported(definition(), String.t()) ::
          :ok | {:error, {:unsupported_capability, String.t()}}
  def ensure_capability_supported(%ProviderDefinition{} = provider, capability) do
    case supports_capability?(provider, capability) do
      true -> :ok
      false -> {:error, {:unsupported_capability, capability}}
    end
  end

  @doc """
  Builds a prepared language-model request for UniversalAIClient.
  """
  @spec build_response_request(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_response_request(runtime, request, opts \\ []),
    do: build_prepared_request(runtime, :language_model, request, opts)

  @doc """
  Builds a prepared embedding request for UniversalAIClient.
  """
  @spec build_embeddings_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_embeddings_request(runtime, request),
    do: build_prepared_request(runtime, :embedding_model, request, [])

  @doc """
  Builds a prepared rerank request for UniversalAIClient.
  """
  @spec build_rerank_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_rerank_request(runtime, request),
    do: build_prepared_request(runtime, :rerank_model, request, [])

  @doc """
  Builds a prepared web-search request for UniversalAIClient.
  """
  @spec build_web_search_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_web_search_request(runtime, request),
    do: build_prepared_request(runtime, :web_search, request, [])

  @doc """
  Builds a prepared web-fetch request for UniversalAIClient.
  """
  @spec build_web_fetch_request(map(), map()) :: {:ok, map()} | {:error, term()}
  def build_web_fetch_request(runtime, request),
    do: build_prepared_request(runtime, :web_fetch, request, [])

  @doc """
  Returns connection option keys accepted by a provider definition.

  Common keys such as `transport`, `headers`, and `query_params` are handled by
  `UniversalAIRequest`, so each provider does not need to redeclare them.
  """
  @spec connection_option_keys(definition()) :: [String.t()]
  def connection_option_keys(%ProviderDefinition{} = provider) do
    provider.settings
    |> Enum.filter(&(&1.scope == :connection))
    |> Enum.map(&Atom.to_string(&1.key))
    |> Kernel.++(@common_connection_settings)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns request-scoped provider option keys accepted by a provider definition.
  """
  @spec runtime_provider_option_keys(definition()) :: [String.t()]
  def runtime_provider_option_keys(%ProviderDefinition{} = provider) do
    provider.settings
    |> Enum.filter(&(&1.scope == :request))
    |> Enum.map(&Atom.to_string(&1.key))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # This is the only dispatch path from resolved runtime maps to provider-owned
  # request preparation. The provider returns a prepared request; Rust still owns
  # transport, response decoding, and downstream chunk generation.
  defp build_prepared_request(runtime, capability_kind, request, opts) do
    with {:ok, provider} <- fetch(Map.get(runtime, "provider_kind")),
         {:ok, capability} <- ProviderDefinition.capability(provider, capability_kind),
         {:ok, ctx} <- PrepareContext.build(provider, capability_kind, runtime, request, opts),
         ctx = apply_provider_request_policies(ctx),
         {:ok, prepared} <- call_prepare(provider.module, capability, ctx) do
      {:ok, prepared}
    end
  end

  defp apply_provider_request_policies(%PrepareContext{} = ctx) do
    maybe_disable_openai_response_storage(ctx)
  end

  defp maybe_disable_openai_response_storage(
         %PrepareContext{
           provider: %ProviderDefinition{provider_kind: provider_kind},
           capability: %Capability{kind: :language_model},
           request: request
         } = ctx
       )
       when provider_kind in ["openai", "azure_openai"] and is_map(request) do
    if openai_responses_endpoint?(provider_kind, ctx) do
      %{ctx | request: Map.put(request, "store", false)}
    else
      ctx
    end
  end

  defp maybe_disable_openai_response_storage(ctx), do: ctx

  defp openai_responses_endpoint?("openai", %PrepareContext{settings: settings})
       when is_map(settings) do
    case Map.get(settings, :endpoint_kind) do
      "chat_completions" -> false
      _endpoint_kind -> true
    end
  end

  defp openai_responses_endpoint?("azure_openai", %PrepareContext{settings: settings})
       when is_map(settings),
       do: Map.get(settings, :endpoint_kind) == "responses"

  defp openai_responses_endpoint?(_provider_kind, _ctx), do: false

  # Provider code can return the builder or the final map, tagged or bare. That
  # keeps simple providers terse while preserving a single UniversalAIClient spec
  # shape after this boundary.
  defp call_prepare(module, %Capability{prepare: function_name}, ctx) do
    case apply(module, function_name, [ctx]) do
      %UniversalAIRequest{} = request -> UniversalAIRequest.to_spec(request)
      request when is_map(request) -> {:ok, request}
      {:ok, %UniversalAIRequest{} = request} -> UniversalAIRequest.to_spec(request)
      {:ok, request} when is_map(request) -> {:ok, request}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_prepared_request, other}}
    end
  end

  defp registry do
    case :persistent_term.get(@cache_key, nil) do
      %{definitions: definitions, by_kind: by_kind} = registry
      when is_list(definitions) and is_map(by_kind) ->
        registry

      _missing ->
        refresh()
    end
  end

  defp build_registry(declarations) do
    definitions =
      declarations
      |> plugin_provider_modules()
      |> then(fn plugin_modules -> @builtins ++ plugin_modules end)
      |> Enum.map(&definition!/1)
      |> Enum.uniq_by(& &1.provider_kind)

    %{
      definitions: definitions,
      by_kind: Map.new(definitions, &{&1.provider_kind, &1})
    }
  end

  defp plugin_provider_modules(declarations) do
    declarations
    |> Enum.filter(fn declaration ->
      declaration[:contract_id] == @contract_id or declaration["contract_id"] == @contract_id
    end)
    |> Enum.flat_map(fn declaration ->
      case declaration_module(declaration) do
        {:ok, module} -> [module]
        {:error, _reason} -> []
      end
    end)
  end

  defp capability_names(%ProviderDefinition{capabilities: capabilities}) do
    capabilities
    |> Enum.map(fn %Capability{kind: kind} -> ProviderDefinition.capability_name(kind) end)
    |> Enum.uniq()
  end

  # Plugin declarations may come from JSON-like data or Elixir maps. Supporting
  # both shapes keeps the plugin contract boring without forcing adapters to
  # agree on atom-vs-string keys.
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

  defp setting_projection(%Setting{} = setting) do
    %{
      "key" => Atom.to_string(setting.key),
      "type" => setting.type && Atom.to_string(setting.type),
      "required" => setting.required?,
      "encrypted" => setting.encrypted?,
      "scope" => Atom.to_string(setting.scope),
      "default" => setting.default
    }
  end

  defp capability_projection(%Capability{} = capability) do
    %{
      "kind" => ProviderDefinition.capability_name(capability.kind),
      "upstream" => Atom.to_string(capability.upstream),
      "api_resolver" => Atom.to_string(capability.api_resolver)
    }
  end

  defp stringify_label(label) when is_map(label) do
    Map.new(label, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_label(label) when is_binary(label), do: %{"default" => label}
  defp stringify_label(_label), do: %{}
end
