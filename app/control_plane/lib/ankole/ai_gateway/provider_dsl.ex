defmodule Ankole.AIGateway.ProviderDSL do
  @moduledoc """
  Small provider declaration DSL for UniversalAIClient request preparation.

  The DSL records provider metadata and capability ownership. It deliberately
  does not describe request body fields; each provider's prepare function is
  normal Elixir code in the same module.
  """

  alias Ankole.AIGateway.ProviderDefinition
  alias Ankole.AIGateway.ProviderDefinition.Capability
  alias Ankole.AIGateway.ProviderDefinition.Setting

  @capability_kinds [
    :language_model,
    :embedding_model,
    :rerank_model,
    :web_search,
    :web_fetch,
    :image_generate
  ]
  @upstream_kinds [:sse, :eventstream, :websocket_text, :json]

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Ankole.AIGateway.ProviderDSL

      Module.register_attribute(__MODULE__, :ai_provider_settings, accumulate: true)
      Module.register_attribute(__MODULE__, :ai_provider_capabilities, accumulate: true)
      Module.register_attribute(__MODULE__, :ai_provider_capability_attrs, accumulate: true)

      @before_compile Ankole.AIGateway.ProviderDSL
    end
  end

  @doc """
  Starts a provider declaration.

  The provider kind is the stable id used by stored provider rows and runtime
  model bindings. Atoms and strings are normalized to snake_case strings so the
  external id format matches the Elixir provider modules without exposing atoms.
  """
  defmacro provider(provider_kind, do: block) do
    quote do
      @ai_provider_kind unquote(provider_kind)
      unquote(block)
    end
  end

  @doc """
  Declares the i18n-ready provider label shown in Console and API projections.
  """
  defmacro label(value) do
    quote do
      @ai_provider_label unquote(value)
    end
  end

  @doc """
  Declares the default base URL used when an operator does not override it.

  Set `advanced: true` when Console should keep the override in its collapsed
  advanced section.
  """
  defmacro base_url(value, opts \\ []) do
    quote bind_quoted: [value: value, opts: opts] do
      @ai_provider_base_url value
      @ai_provider_base_url_advanced Keyword.get(opts, :advanced, false)
    end
  end

  @doc """
  Declares one accepted provider option.

  Settings are metadata for validation, projection, encryption, and defaults.
  Set `advanced: true` for operator fields that Console should collapse by
  default. Select fields declare their accepted string values with `options`.
  String fields can use `options` as editable suggestions without rejecting
  other values. Settings do not define request transformation logic; provider
  prepare functions remain ordinary Elixir code.
  """
  defmacro setting(key, opts \\ []) do
    quote bind_quoted: [key: key, opts: opts] do
      Ankole.AIGateway.ProviderDSL.__put_setting__(__MODULE__, key, opts)
    end
  end

  @doc "Declares the provider's language-model capability."
  defmacro language_model(do: block), do: capability(:language_model, block)

  @doc "Declares the provider's embedding-model capability."
  defmacro embedding_model(do: block), do: capability(:embedding_model, block)

  @doc "Declares the provider's rerank-model capability."
  defmacro rerank_model(do: block), do: capability(:rerank_model, block)

  @doc "Declares the provider's web-search capability."
  defmacro web_search(do: block), do: capability(:web_search, block)

  @doc "Declares the provider's web-fetch capability."
  defmacro web_fetch(do: block), do: capability(:web_fetch, block)

  @doc "Declares the provider's image-generation capability."
  defmacro image_generate(do: block), do: capability(:image_generate, block)

  @doc """
  Declares the upstream wire shape consumed by UniversalAIClient.

  This is deliberately separate from `api_resolver`: unusual providers can use
  an existing API protocol over a different transport without adding a combo
  registry.
  """
  defmacro upstream(kind) do
    quote do
      @ai_provider_capability_attrs {:upstream, unquote(kind)}
    end
  end

  @doc """
  Declares the Rust API protocol resolver used for this capability.

  The resolver owns provider request-body encoding plus response parsing and
  normalization for one upstream API shape. URL, headers, auth, and provider
  option lookup stay in Elixir provider code.
  """
  defmacro api_resolver(resolver) do
    quote do
      @ai_provider_capability_attrs {:api_resolver, unquote(resolver)}
    end
  end

  @doc """
  Declares the provider function that builds the prepared request.
  """
  defmacro prepare(function_name) do
    quote do
      @ai_provider_capability_attrs {:prepare, unquote(function_name)}
    end
  end

  @doc """
  Declares a capability-specific timeout override in milliseconds.
  """
  defmacro timeout_ms(value) do
    quote do
      @ai_provider_capability_attrs {:timeout_ms, unquote(value)}
    end
  end

  @doc """
  Declares that this provider capability accepts parallel tool calls.
  """
  defmacro supports_parallel_tool_calls(value \\ true) do
    quote do
      @ai_provider_capability_attrs {:supports_parallel_tool_calls, unquote(value)}
    end
  end

  @doc """
  Declares that this provider can execute the public native image-generation
  tool without an AIGateway hosted image profile.
  """
  defmacro supports_native_image_generation(value \\ true) do
    quote do
      @ai_provider_capability_attrs {:supports_native_image_generation, unquote(value)}
    end
  end

  @doc """
  Declares that this provider runs web search inside its own model turn.

  The provider owns the search loop and its citations. An Agent chooses whether
  to use it; this only states that the provider can.
  """
  defmacro supports_native_web_search(value \\ true) do
    quote do
      @ai_provider_capability_attrs {:supports_native_web_search, unquote(value)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    provider_kind =
      env.module
      |> Module.get_attribute(:ai_provider_kind)
      |> normalize_provider_kind()

    label = Module.get_attribute(env.module, :ai_provider_label) || %{}
    base_url = Module.get_attribute(env.module, :ai_provider_base_url)
    base_url_advanced? = Module.get_attribute(env.module, :ai_provider_base_url_advanced) || false
    settings = Module.get_attribute(env.module, :ai_provider_settings) |> Enum.reverse()
    capabilities = Module.get_attribute(env.module, :ai_provider_capabilities) |> Enum.reverse()

    definition = %ProviderDefinition{
      provider_kind: provider_kind,
      label: normalize_label(label),
      module: env.module,
      base_url: base_url,
      base_url_advanced?: base_url_advanced?,
      settings: settings,
      capabilities: capabilities
    }

    quote do
      @behaviour Ankole.AIGateway.Provider

      @impl true
      def provider_definition, do: unquote(Macro.escape(definition))
    end
  end

  @doc false
  def __put_setting__(module, key, opts) do
    scope = Keyword.get(opts, :scope, :connection)
    encrypted? = Keyword.get(opts, :encrypted, false)

    # Secrets live only in the encrypted credential pool. Connection and
    # request settings are stored and projected in plain form, so an encrypted
    # declaration outside :credential scope would store its value unprotected
    # and return it to API readers.
    if encrypted? and scope != :credential do
      raise ArgumentError,
            "encrypted setting #{inspect(key)} in #{inspect(module)} must use scope: :credential"
    end

    setting = %Setting{
      key: normalize_setting_key(key),
      type: Keyword.get(opts, :type),
      default: Keyword.get(opts, :default),
      options: normalize_setting_options(Keyword.get(opts, :options, [])),
      required?: Keyword.get(opts, :required, false),
      encrypted?: encrypted?,
      advanced?: Keyword.get(opts, :advanced, false),
      scope: scope
    }

    Module.put_attribute(module, :ai_provider_settings, setting)
  end

  @doc false
  def __put_capability__(module, kind) when kind in @capability_kinds do
    attrs =
      module
      |> Module.get_attribute(:ai_provider_capability_attrs)
      |> Enum.reverse()
      |> Map.new()

    upstream = Map.fetch!(attrs, :upstream)
    api_resolver = Map.fetch!(attrs, :api_resolver)
    prepare = Map.fetch!(attrs, :prepare)
    supports_parallel_tool_calls? = Map.get(attrs, :supports_parallel_tool_calls, false)

    supports_native_image_generation? =
      Map.get(attrs, :supports_native_image_generation, false)

    supports_native_web_search? = Map.get(attrs, :supports_native_web_search, false)

    unless upstream in @upstream_kinds do
      raise ArgumentError,
            "unsupported upstream #{inspect(upstream)} for #{inspect(module)} #{kind}"
    end

    unless is_boolean(supports_parallel_tool_calls?) do
      raise ArgumentError,
            "supports_parallel_tool_calls must be a boolean for #{inspect(module)} #{kind}"
    end

    unless is_boolean(supports_native_image_generation?) do
      raise ArgumentError,
            "supports_native_image_generation must be a boolean for #{inspect(module)} #{kind}"
    end

    capability = %Capability{
      kind: kind,
      upstream: upstream,
      api_resolver: api_resolver,
      prepare: prepare,
      timeout_ms: Map.get(attrs, :timeout_ms),
      supports_parallel_tool_calls?: supports_parallel_tool_calls?,
      supports_native_image_generation?: supports_native_image_generation?,
      supports_native_web_search?: supports_native_web_search?
    }

    Module.put_attribute(module, :ai_provider_capabilities, capability)
    Module.delete_attribute(module, :ai_provider_capability_attrs)
  end

  # Capability attributes are scoped to one block. Deleting the temporary
  # attribute before and after the block prevents one capability declaration
  # from accidentally inheriting resolver or upstream settings from another.
  defp capability(kind, block) do
    quote do
      Module.delete_attribute(__MODULE__, :ai_provider_capability_attrs)
      unquote(block)
      Ankole.AIGateway.ProviderDSL.__put_capability__(__MODULE__, unquote(kind))
    end
  end

  defp normalize_provider_kind(nil), do: raise(ArgumentError, "provider id is required")

  defp normalize_provider_kind(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_provider_kind()

  defp normalize_provider_kind(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase() |> String.replace("-", "_")

  defp normalize_label(value) when is_binary(value), do: %{"default" => value}
  defp normalize_label(value) when is_map(value), do: value
  defp normalize_label(_value), do: %{}

  defp normalize_setting_key(key) when is_atom(key), do: key
  defp normalize_setting_key(key) when is_binary(key), do: String.to_atom(key)

  defp normalize_setting_options(options) when is_list(options) do
    Enum.map(options, fn
      value when is_binary(value) ->
        value

      value when is_atom(value) ->
        Atom.to_string(value)

      value ->
        raise ArgumentError, "provider setting options must be strings, got: #{inspect(value)}"
    end)
  end
end
