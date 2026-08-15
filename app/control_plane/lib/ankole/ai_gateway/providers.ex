defmodule Ankole.AIGateway.Providers do
  @moduledoc """
  Provider registry and request dispatcher for AIGateway.

  Provider modules expose a compiled `ProviderDefinition`. Runtime request
  dispatch creates a `PrepareContext`, calls the capability's provider-owned
  prepare function, and hands the resulting prepared request to the native
  UniversalAIClient path.
  """

  alias Ankole.AIGateway.PrepareContext
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.ProviderConfigs
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
    Ankole.AIGateway.Providers.ChatGPTSubscription,
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
      "credential_options" => credential_option_keys(provider),
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
         :ok <- validate_setting_options(provider, :connection, options, :connection_options),
         :ok <- validate_provider_connection_options(provider, options) do
      {:ok, options}
    end
  end

  def normalize_connection_options(_provider_kind, _options),
    do: {:error, :invalid_connection_options}

  @doc """
  Normalizes and validates one provider credential payload.

  Credential metadata such as the pool entry id and label is not part of this
  payload. Required fields and select values are checked before plaintext is
  encrypted so an unusable credential cannot enter the pool.
  """
  @spec normalize_credential_options(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_credential_options(provider_kind, options) when is_map(options) do
    options = normalize_option_keys(options)

    with {:ok, provider} <- fetch(provider_kind),
         :ok <-
           reject_unknown_keys(options, credential_option_keys(provider), :credential_options),
         :ok <- validate_setting_options(provider, :credential, options, :credential_options),
         :ok <-
           validate_required_setting_options(
             provider,
             :credential,
             options,
             :credential_options
           ),
         :ok <- validate_provider_credential_options(provider, options) do
      {:ok, options}
    end
  end

  def normalize_credential_options(_provider_kind, _options),
    do: {:error, :invalid_credential_options}

  defp validate_provider_connection_options(provider, options) do
    if function_exported?(provider.module, :validate_connection_options, 1) do
      provider.module.validate_connection_options(options)
    else
      :ok
    end
  end

  defp validate_provider_credential_options(provider, options) do
    if function_exported?(provider.module, :validate_credential_options, 1) do
      provider.module.validate_credential_options(options)
    else
      :ok
    end
  end

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
  Returns whether the selected language-model provider executes the public
  `image_generation` tool itself.
  """
  @spec supports_native_image_generation?(map()) :: boolean()
  def supports_native_image_generation?(%{"provider_kind" => provider_kind}) do
    with {:ok, provider} <- fetch(provider_kind),
         {:ok, capability} <- ProviderDefinition.capability(provider, :language_model) do
      capability.supports_native_image_generation?
    else
      _error -> false
    end
  end

  def supports_native_image_generation?(_runtime), do: false

  @doc """
  Returns whether the selected language-model provider runs web search itself.

  A provider whose wire protocol always carries the capability declares it. A
  generic OpenAI-compatible row cannot be known statically, because its endpoint
  is whatever the operator pointed it at, so it counts when that row is configured
  for the Responses wire, which is the protocol hosted web search belongs to.
  An endpoint that claims the Responses wire and cannot serve hosted tools has
  an incomplete protocol; that is an upstream error, not a case for an extra
  connection switch.

  This answers only what the provider can do. Whether an Agent uses it is the
  Agent's `provider_hosted` setting.
  """
  @spec supports_native_web_search?(map()) :: boolean()
  def supports_native_web_search?(%{"provider_kind" => provider_kind} = model_ref) do
    declared? =
      with {:ok, provider} <- fetch(provider_kind),
           {:ok, capability} <- ProviderDefinition.capability(provider, :language_model) do
        capability.supports_native_web_search?
      else
        _error -> false
      end

    declared? or ProviderConfigs.responses_endpoint?(model_ref)
  end

  def supports_native_web_search?(_runtime), do: false

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
  Returns the effective language-model resolver for one resolved runtime.

  OpenAI-family providers select the resolver from their effective endpoint.
  Other providers use their declared resolver.
  """
  @spec effective_language_model_api_resolver(map()) :: {:ok, atom()} | {:error, term()}
  def effective_language_model_api_resolver(%{"provider_kind" => provider_kind} = runtime) do
    with {:ok, provider} <- fetch(provider_kind),
         {:ok, capability} <- ProviderDefinition.capability(provider, :language_model) do
      resolver =
        if provider_kind in ~w(openai openai_compatible azure_openai chatgpt_subscription) do
          openai_family_api_resolver(responses_endpoint?(runtime))
        else
          capability.api_resolver
        end

      {:ok, resolver}
    end
  end

  def effective_language_model_api_resolver(_runtime),
    do: {:error, :unknown_ai_gateway_provider}

  @doc """
  Maps the Responses-wire judgment to the native API resolver shared by the
  OpenAI protocol family. The native side normalizes the two OpenAI stream
  formats differently, so the resolver must follow the effective endpoint.
  """
  @spec openai_family_api_resolver(boolean()) :: :openai_responses | :openai_chat_completions
  def openai_family_api_resolver(true), do: :openai_responses
  def openai_family_api_resolver(false), do: :openai_chat_completions

  @doc """
  Returns whether one provider connection speaks the OpenAI Responses wire.

  This is the only owner of the per-kind endpoint defaults: `openai` defaults
  to Responses, `azure_openai` and `openai_compatible` default to Chat
  Completions because that is the most common generic shape, and
  `chatgpt_subscription` always speaks Responses. A missing or unknown
  `endpoint_kind` connection option falls back to the kind's default.
  """
  @spec responses_endpoint?(String.t(), map()) :: boolean()
  def responses_endpoint?("chatgpt_subscription", _connection_options), do: true

  def responses_endpoint?("openai", connection_options) do
    Map.get(connection_options, "endpoint_kind") != "chat_completions"
  end

  def responses_endpoint?(provider_kind, connection_options)
      when provider_kind in ["openai_compatible", "azure_openai"] do
    Map.get(connection_options, "endpoint_kind") == "responses"
  end

  def responses_endpoint?(_provider_kind, _connection_options), do: false

  @doc """
  Returns whether one prepare context or one resolved runtime uses the
  Responses endpoint. Both shapes read the `endpoint_kind` connection setting
  and delegate to `responses_endpoint?/2`.
  """
  @spec responses_endpoint?(PrepareContext.t() | map()) :: boolean()
  def responses_endpoint?(%PrepareContext{} = ctx) do
    responses_endpoint?(
      ctx.provider.provider_kind,
      %{"endpoint_kind" => ctx.settings[:endpoint_kind]}
    )
  end

  def responses_endpoint?(%{"provider_kind" => provider_kind} = runtime) do
    responses_endpoint?(provider_kind, Map.get(runtime, "connection_options", %{}))
  end

  def responses_endpoint?(_runtime), do: false

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
  Returns the provider-specific fields stored in each encrypted credential entry.
  """
  @spec credential_option_keys(definition()) :: [String.t()]
  def credential_option_keys(%ProviderDefinition{} = provider) do
    provider.settings
    |> Enum.filter(&(&1.scope == :credential))
    |> Enum.map(&Atom.to_string(&1.key))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns whether a provider requires at least one credential field.

  Providers with only optional credential settings can use one empty pool
  member for anonymous upstream access.
  """
  @spec credential_required?(definition()) :: boolean()
  def credential_required?(%ProviderDefinition{} = provider) do
    Enum.any?(provider.settings, &(&1.scope == :credential and &1.required?))
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
      rebuild = fn next_runtime, request_override ->
        build_prepared_request(
          next_runtime,
          capability_kind,
          request_override || request,
          opts
        )
      end

      {:ok, CredentialAttempts.attach(prepared, runtime, rebuild, request)}
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
       when provider_kind in ["openai", "azure_openai"] and
              is_map(request) do
    if responses_endpoint?(ctx) do
      %{ctx | request: Map.put(request, "store", false)}
    else
      ctx
    end
  end

  defp maybe_disable_openai_response_storage(ctx), do: ctx

  # Provider code can return the builder or the final map, tagged or bare. That
  # keeps simple providers terse while preserving a single UniversalAIClient spec
  # shape after this boundary.
  defp call_prepare(module, %Capability{prepare: function_name}, ctx) do
    call_prepare_function(module, function_name, ctx)
  end

  defp call_prepare_function(module, function_name, ctx) do
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
      callbacks = [capability.prepare] |> Enum.reject(&is_nil/1)

      case Enum.find_value(callbacks, :ok, fn callback ->
             case validate_module_callback(module, callback, 1) do
               :ok -> false
               {:error, reason} -> {:error, reason}
             end
           end) do
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
      "api_resolver" => Atom.to_string(capability.api_resolver),
      "supports_parallel_tool_calls" => capability.supports_parallel_tool_calls?,
      "supports_native_image_generation" => capability.supports_native_image_generation?
    }
  end

  # The Console API is a public contract, so a declared setting type is enforced
  # here and not only in the operator form. Every declared type has its own
  # clause, and an undeclared one is rejected, so a new setting type cannot pass
  # validation by omission and then read as a wrong value at request time.
  defp validate_setting_options(provider, scope, options, error_tag) do
    provider.settings
    |> Enum.filter(&(&1.scope == scope))
    |> Enum.reduce_while(:ok, fn setting, :ok ->
      key = Atom.to_string(setting.key)

      case Map.fetch(options, key) do
        :error -> {:cont, :ok}
        {:ok, value} -> validate_setting_value(setting, key, value, error_tag)
      end
    end)
  end

  # A cleared option carries no shape to check. Whether it may be absent is
  # `validate_required_setting_options/4`'s decision, not this one's.
  defp validate_setting_value(%Setting{}, _key, nil, _error_tag), do: {:cont, :ok}

  defp validate_setting_value(%Setting{type: :select} = setting, key, value, error_tag) do
    if value in setting.options do
      {:cont, :ok}
    else
      {:halt, {:error, {error_tag, {:invalid_value, key, value, setting.options}}}}
    end
  end

  defp validate_setting_value(%Setting{type: :boolean}, _key, value, _error_tag)
       when is_boolean(value),
       do: {:cont, :ok}

  defp validate_setting_value(%Setting{type: :integer}, _key, value, _error_tag)
       when is_integer(value),
       do: {:cont, :ok}

  defp validate_setting_value(%Setting{type: :map}, _key, value, _error_tag)
       when is_map(value),
       do: {:cont, :ok}

  # A setting without a declared type carries no shape constraint. A credential
  # such as `api_key` accepts a plain token or a JSON object of provider-specific
  # parts, and only the provider knows which.
  defp validate_setting_value(%Setting{type: nil}, _key, _value, _error_tag), do: {:cont, :ok}

  defp validate_setting_value(%Setting{type: type}, key, value, error_tag)
       when type in [:select, :boolean, :integer, :map],
       do: {:halt, {:error, {error_tag, {:invalid_setting_type, key, type, value}}}}

  defp validate_setting_value(%Setting{type: type}, key, _value, error_tag),
    do: {:halt, {:error, {error_tag, {:unsupported_setting_type, key, type}}}}

  defp validate_required_setting_options(provider, scope, options, error_tag) do
    provider.settings
    |> Enum.filter(&(&1.scope == scope and &1.required?))
    |> Enum.reduce_while(:ok, fn setting, :ok ->
      key = Atom.to_string(setting.key)
      value = Map.get(options, key, setting.default)

      if present_setting_value?(value) do
        {:cont, :ok}
      else
        {:halt, {:error, {error_tag, {:required, key}}}}
      end
    end)
  end

  defp present_setting_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_setting_value?(value), do: not is_nil(value)

  defp stringify_label(label) when is_map(label) do
    Map.new(label, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp stringify_label(label) when is_binary(label), do: %{"default" => label}
  defp stringify_label(_label), do: %{}
end
