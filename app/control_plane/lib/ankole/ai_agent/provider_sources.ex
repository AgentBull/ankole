defmodule Ankole.AIAgent.ProviderSources do
  @moduledoc """
  First-party registry for LLM provider sources.

  Operator-facing vocabulary is intentionally small: provider rows use
  `provider_source`, while adapter-specific names stay in metadata returned to
  the worker.
  """

  # Header names an operator is forbidden from setting in `connection_options`.
  # Credentials must flow through the sealed `encrypted_credential` column, not
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

  @profiles ~w(primary light heavy codex)

  @type source :: String.t()
  @type validation_result :: :ok | {:error, term()}

  defmodule Source do
    @moduledoc """
    Static metadata for one provider source.
    """

    @enforce_keys [
      :source,
      :label,
      :adapter,
      :adapter_strategy,
      :codex_compatible?,
      :default_base_url,
      :connection_option_keys,
      :runtime_provider_option_keys,
      :credential_modes
    ]
    defstruct [
      :source,
      :label,
      :adapter,
      :adapter_strategy,
      :codex_compatible?,
      :default_base_url,
      :connection_option_keys,
      :runtime_provider_option_keys,
      :credential_modes,
      :model_catalog_policy
    ]

    @type t :: %__MODULE__{
            source: String.t(),
            label: String.t(),
            adapter: String.t(),
            adapter_strategy: String.t(),
            codex_compatible?: boolean(),
            default_base_url: String.t(),
            connection_option_keys: [String.t()],
            runtime_provider_option_keys: [String.t()],
            credential_modes: [String.t()],
            model_catalog_policy: String.t()
          }
  end

  # One static entry per supported source. The two key-list fields are
  # allowlists used to reject unknown options: `connection_option_keys` gates
  # what an operator may store on a provider row, `runtime_provider_option_keys`
  # gates the per-call options an agent profile may carry. `model_catalog_policy`
  # records how much the source constrains model names (known list vs. anything).
  @source_attrs [
    %{
      source: "openrouter",
      label: "OpenRouter",
      adapter: "openai_compatible",
      adapter_strategy: "openai_compatible",
      codex_compatible?: true,
      default_base_url: "https://openrouter.ai/api/v1",
      connection_option_keys:
        ~w(base_url headers query_params include_usage supports_structured_outputs),
      runtime_provider_option_keys: ~w(user reasoningEffort textVerbosity strictJsonSchema),
      credential_modes: ~w(api_key),
      model_catalog_policy: "provider_specific"
    },
    %{
      source: "openai",
      label: "OpenAI",
      adapter: "openai",
      adapter_strategy: "openai_official_or_compatible",
      codex_compatible?: true,
      default_base_url: "https://api.openai.com/v1",
      connection_option_keys:
        ~w(endpoint_kind base_url organization project headers query_params include_usage supports_structured_outputs),
      runtime_provider_option_keys:
        ~w(reasoningEffort reasoningSummary promptCacheKey promptCacheRetention serviceTier strictJsonSchema textVerbosity truncation systemMessageMode forceReasoning contextManagement allowedTools),
      credential_modes: ~w(api_key),
      model_catalog_policy: "known_or_provider_specific"
    },
    %{
      source: "claude",
      label: "Claude",
      adapter: "anthropic",
      adapter_strategy: "anthropic",
      codex_compatible?: false,
      default_base_url: "https://api.anthropic.com/v1",
      connection_option_keys: ~w(base_url auth_mode headers),
      runtime_provider_option_keys:
        ~w(thinking cacheControl structuredOutputMode toolStreaming effort taskBudget speed inferenceGeo anthropicBeta contextManagement),
      credential_modes: ~w(api_key auth_token),
      model_catalog_policy: "known_or_custom"
    },
    %{
      source: "gemini",
      label: "Gemini",
      adapter: "google",
      adapter_strategy: "google",
      codex_compatible?: false,
      default_base_url: "https://generativelanguage.googleapis.com/v1beta",
      connection_option_keys: ~w(base_url headers),
      runtime_provider_option_keys:
        ~w(thinkingConfig structuredOutputs safetySettings responseModalities cachedContent labels mediaResolution serviceTier requestType),
      credential_modes: ~w(api_key),
      model_catalog_policy: "known_or_custom"
    }
  ]

  @doc """
  Returns the fixed model profile names.
  """
  @spec profiles() :: [String.t()]
  def profiles, do: @profiles

  @doc """
  Returns every provider source.
  """
  @spec all() :: [Source.t()]
  def all, do: Enum.map(@source_attrs, &struct(Source, &1))

  @doc """
  Fetches one source by operator-facing id.
  """
  @spec fetch(source()) :: {:ok, Source.t()} | {:error, :unknown_provider_source}
  def fetch(source) when is_binary(source) do
    normalized = normalize_source(source)

    case Enum.find(all(), &(&1.source == normalized)) do
      %Source{} = source -> {:ok, source}
      nil -> {:error, :unknown_provider_source}
    end
  end

  def fetch(_source), do: {:error, :unknown_provider_source}

  @doc """
  Projects source metadata for console/API use.
  """
  @spec projection(Source.t()) :: map()
  def projection(%Source{} = source) do
    %{
      "provider_source" => source.source,
      "label" => source.label,
      "codex_compatible" => source.codex_compatible?,
      "adapter_strategy" => source.adapter_strategy,
      "default_base_url" => source.default_base_url,
      "credential_modes" => source.credential_modes,
      "connection_options" => source.connection_option_keys,
      "runtime_provider_options" => source.runtime_provider_option_keys,
      "model_catalog_policy" => source.model_catalog_policy
    }
  end

  @doc """
  Validates and normalizes provider connection options.
  """
  @spec normalize_connection_options(source(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_connection_options(source, options) when is_map(options) do
    with {:ok, source} <- fetch(source),
         :ok <- reject_unknown_keys(options, source.connection_option_keys, :connection_options),
         :ok <- validate_headers(Map.get(options, "headers")),
         :ok <- validate_query_params(Map.get(options, "query_params")),
         :ok <- validate_endpoint_kind(source.source, Map.get(options, "endpoint_kind")),
         :ok <- validate_auth_mode(source.source, Map.get(options, "auth_mode")) do
      {:ok, normalize_option_keys(options)}
    end
  end

  def normalize_connection_options(_source, _options), do: {:error, :invalid_connection_options}

  @doc """
  Validates source-specific per-call provider options stored on an agent profile.
  """
  @spec validate_runtime_provider_options(source(), map()) :: validation_result()
  def validate_runtime_provider_options(source, options) when is_map(options) do
    with {:ok, source} <- fetch(source) do
      reject_unknown_keys(options, source.runtime_provider_option_keys, :provider_options)
    end
  end

  def validate_runtime_provider_options(_source, _options),
    do: {:error, :invalid_provider_options}

  @doc """
  Validates that a credential mode is accepted by the source.
  """
  @spec validate_credential_mode(source(), String.t()) :: validation_result()
  def validate_credential_mode(source, mode) when is_binary(mode) do
    with {:ok, source} <- fetch(source) do
      case mode in source.credential_modes do
        true -> :ok
        false -> {:error, :unsupported_credential_mode}
      end
    end
  end

  def validate_credential_mode(_source, _mode), do: {:error, :unsupported_credential_mode}

  @doc """
  Returns true when the source can back the Codex model profile.
  """
  @spec codex_compatible?(source()) :: boolean()
  def codex_compatible?(source) do
    case fetch(source) do
      {:ok, %Source{codex_compatible?: compatible?}} -> compatible?
      {:error, _reason} -> false
    end
  end

  defp normalize_source(source), do: source |> String.trim() |> String.downcase()

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

  defp validate_endpoint_kind("openai", nil), do: :ok
  defp validate_endpoint_kind("openai", kind) when kind in ["official", "compatible"], do: :ok
  defp validate_endpoint_kind("openai", _kind), do: {:error, :invalid_endpoint_kind}
  defp validate_endpoint_kind(_source, nil), do: :ok
  defp validate_endpoint_kind(_source, _kind), do: {:error, :endpoint_kind_not_supported}

  defp validate_auth_mode("claude", nil), do: :ok
  defp validate_auth_mode("claude", mode) when mode in ["api_key", "auth_token"], do: :ok
  defp validate_auth_mode("claude", _mode), do: {:error, :invalid_auth_mode}
  defp validate_auth_mode(_source, nil), do: :ok
  defp validate_auth_mode(_source, _mode), do: {:error, :auth_mode_not_supported}
end
