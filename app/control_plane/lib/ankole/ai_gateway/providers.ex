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
  @plugin_provider_kind_pattern ~r/\A[a-z][a-z0-9_]{0,62}\z/
  @capability_kinds [
    :language_model,
    :embedding_model,
    :rerank_model,
    :web_search,
    :web_fetch,
    :image_generate
  ]
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
  Plugin provider declaration errors are startup configuration errors and are
  rejected before the provider registry cache is published.
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
    case build_registry(declarations) do
      {:ok, registry} ->
        :persistent_term.put(@cache_key, registry)
        registry

      {:error, reason} ->
        raise ArgumentError, "invalid AI Gateway provider declaration: #{inspect(reason)}"
    end
  end

  @doc false
  @spec validate_adapter_declaration(map()) :: :ok | {:error, term()}
  def validate_adapter_declaration(declaration) when is_map(declaration) do
    with {:ok, _definition} <- plugin_provider_definition(declaration) do
      :ok
    end
  end

  def validate_adapter_declaration(declaration),
    do: {:error, {:invalid_ai_gateway_provider_declaration, declaration}}

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
      "settings" => [
        base_url_setting_projection(provider) | Enum.map(provider.settings, &setting_projection/1)
      ],
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
           reject_unknown_keys(options, connection_option_keys(provider), :connection_options),
         :ok <- validate_setting_options(provider, :connection, options, :connection_options) do
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
    options = normalize_option_keys(options)

    with {:ok, provider} <- fetch(provider_kind),
         :ok <-
           reject_unknown_keys(options, runtime_provider_option_keys(provider), :provider_options) do
      validate_setting_options(provider, :request, options, :provider_options)
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
  Builds an OpenRouter image-generation request for HostedResponsesExecutor.

  Image generation is an internal AIGateway capability. It is not exposed as a
  worker function tool and is only composed into a Responses request by the
  hosted-tool preparation path.
  """
  @spec build_image_generate_request(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_image_generate_request(runtime, request, opts \\ []),
    do: build_prepared_request(runtime, :image_generate, request, opts)

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
    with {:ok, plugin_definitions} <- plugin_provider_definitions(declarations) do
      definitions =
        @builtins
        |> Enum.map(&definition!/1)
        |> Kernel.++(plugin_definitions)
        |> Enum.uniq_by(& &1.provider_kind)

      {:ok,
       %{
         definitions: definitions,
         by_kind: Map.new(definitions, &{&1.provider_kind, &1})
       }}
    end
  end

  defp plugin_provider_definitions(declarations) do
    declarations
    |> Enum.filter(fn declaration ->
      declaration[:contract_id] == @contract_id or declaration["contract_id"] == @contract_id
    end)
    |> Enum.reduce_while({:ok, []}, fn declaration, {:ok, acc} ->
      case plugin_provider_definition(declaration) do
        {:ok, definition} -> {:cont, {:ok, [definition | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp plugin_provider_definition(declaration) do
    with {:ok, declaration_id} <- declaration_id(declaration),
         :ok <- validate_plugin_provider_kind(declaration_id),
         {:ok, module} <- declaration_module(declaration),
         :ok <- validate_module_callback(module, :provider_definition, 0),
         {:ok, definition} <- provider_definition(module),
         :ok <- validate_plugin_provider_definition(declaration_id, module, definition) do
      {:ok, definition}
    end
  end

  defp validate_plugin_provider_definition(
         declaration_id,
         module,
         %ProviderDefinition{} = definition
       ) do
    with :ok <- validate_plugin_provider_kind(definition.provider_kind),
         :ok <- validate_provider_kind_match(declaration_id, definition.provider_kind),
         :ok <- validate_provider_module(module, definition.module),
         :ok <- validate_plugin_capabilities(definition),
         :ok <- validate_plugin_prepare_callbacks(module, definition) do
      :ok
    end
  end

  defp validate_provider_kind_match(kind, kind), do: :ok

  defp validate_provider_kind_match(declaration_id, provider_kind),
    do: {:error, {:ai_gateway_provider_id_mismatch, declaration_id, provider_kind}}

  defp validate_provider_module(module, module), do: :ok

  defp validate_provider_module(module, definition_module),
    do: {:error, {:ai_gateway_provider_module_mismatch, module, definition_module}}

  defp validate_plugin_provider_kind(provider_kind) when is_binary(provider_kind) do
    case Regex.match?(@plugin_provider_kind_pattern, provider_kind) do
      true -> :ok
      false -> {:error, {:invalid_ai_gateway_provider_kind, provider_kind}}
    end
  end

  defp validate_plugin_provider_kind(provider_kind),
    do: {:error, {:invalid_ai_gateway_provider_kind, provider_kind}}

  defp validate_plugin_capabilities(%ProviderDefinition{capabilities: capabilities})
       when is_list(capabilities) do
    case Enum.all?(capabilities, &valid_plugin_capability?/1) do
      true -> :ok
      false -> {:error, {:invalid_ai_gateway_capabilities, capabilities}}
    end
  end

  defp validate_plugin_capabilities(%ProviderDefinition{capabilities: capabilities}),
    do: {:error, {:invalid_ai_gateway_capabilities, capabilities}}

  defp valid_plugin_capability?(%Capability{kind: kind, prepare: prepare})
       when kind in @capability_kinds and is_atom(prepare),
       do: true

  defp valid_plugin_capability?(_capability), do: false

  defp validate_plugin_prepare_callbacks(module, %ProviderDefinition{capabilities: capabilities}) do
    Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
      case validate_module_callback(module, capability.prepare, 1) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp provider_definition(module) do
    case module.provider_definition() do
      %ProviderDefinition{} = definition -> {:ok, definition}
      value -> {:error, {:invalid_ai_gateway_provider_definition, value}}
    end
  end

  defp capability_names(%ProviderDefinition{capabilities: capabilities}) do
    capabilities
    |> Enum.map(fn %Capability{kind: kind} -> ProviderDefinition.capability_name(kind) end)
    |> Enum.uniq()
  end

  defp declaration_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp declaration_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp declaration_id(_declaration), do: {:error, :missing_provider_id}

  defp declaration_module(%{"module" => module}) when is_atom(module),
    do: ensure_module_loaded(module)

  defp declaration_module(%{module: module}) when is_atom(module),
    do: ensure_module_loaded(module)

  defp declaration_module(_declaration), do: {:error, :missing_provider_module}

  defp ensure_module_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      {:error, reason} -> {:error, {:provider_module_not_loaded, module, reason}}
    end
  end

  defp validate_module_callback(module, function, arity) do
    case function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:missing_provider_callback, module, function, arity}}
    end
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
      "type" => Atom.to_string(setting.type || :string),
      "required" => setting.required?,
      "encrypted" => setting.encrypted?,
      "advanced" => setting.advanced?,
      "scope" => Atom.to_string(setting.scope),
      "default" => setting.default,
      "options" => setting.options
    }
  end

  defp base_url_setting_projection(%ProviderDefinition{} = provider) do
    setting_projection(%Setting{
      key: :base_url,
      default: provider.base_url,
      advanced?: provider.base_url_advanced?
    })
  end

  defp capability_projection(%Capability{} = capability) do
    %{
      "kind" => ProviderDefinition.capability_name(capability.kind),
      "upstream" => Atom.to_string(capability.upstream),
      "api_resolver" => Atom.to_string(capability.api_resolver)
    }
  end

  defp validate_setting_options(provider, scope, options, error_tag) do
    provider.settings
    |> Enum.filter(&(&1.scope == scope and &1.type == :select))
    |> Enum.reduce_while(:ok, fn setting, :ok ->
      key = Atom.to_string(setting.key)

      case Map.fetch(options, key) do
        :error ->
          {:cont, :ok}

        {:ok, value} ->
          if value in setting.options do
            {:cont, :ok}
          else
            {:halt, {:error, {error_tag, {:invalid_value, key, value, setting.options}}}}
          end
      end
    end)
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
