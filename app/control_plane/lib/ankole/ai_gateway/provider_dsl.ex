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

  @capability_kinds [:language_model, :embedding_model, :rerank_model]
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
  model bindings. Atoms are normalized to kebab-case strings so Elixir module
  names do not leak into the external id format.
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
  """
  defmacro base_url(value) do
    quote do
      @ai_provider_base_url unquote(value)
    end
  end

  @doc """
  Declares one accepted provider option.

  Settings are metadata for validation, projection, encryption, and defaults.
  They do not define request transformation logic; provider prepare functions
  remain ordinary Elixir code.
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

  @doc false
  defmacro __before_compile__(env) do
    provider_kind =
      env.module
      |> Module.get_attribute(:ai_provider_kind)
      |> normalize_provider_kind()

    label = Module.get_attribute(env.module, :ai_provider_label) || %{}
    base_url = Module.get_attribute(env.module, :ai_provider_base_url)
    settings = Module.get_attribute(env.module, :ai_provider_settings) |> Enum.reverse()
    capabilities = Module.get_attribute(env.module, :ai_provider_capabilities) |> Enum.reverse()

    definition = %ProviderDefinition{
      provider_kind: provider_kind,
      label: normalize_label(label),
      module: env.module,
      base_url: base_url,
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
    setting = %Setting{
      key: normalize_setting_key(key),
      type: Keyword.get(opts, :type),
      default: Keyword.get(opts, :default),
      required?: Keyword.get(opts, :required, false),
      encrypted?: Keyword.get(opts, :encrypted, false),
      scope: Keyword.get(opts, :scope, :connection)
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

    unless upstream in @upstream_kinds do
      raise ArgumentError,
            "unsupported upstream #{inspect(upstream)} for #{inspect(module)} #{kind}"
    end

    capability = %Capability{
      kind: kind,
      upstream: upstream,
      api_resolver: api_resolver,
      prepare: prepare,
      timeout_ms: Map.get(attrs, :timeout_ms)
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
    do: value |> Atom.to_string() |> String.replace("_", "-")

  defp normalize_provider_kind(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_label(value) when is_binary(value), do: %{"default" => value}
  defp normalize_label(value) when is_map(value), do: value
  defp normalize_label(_value), do: %{}

  defp normalize_setting_key(key) when is_atom(key), do: key
  defp normalize_setting_key(key) when is_binary(key), do: String.to_atom(key)
end
