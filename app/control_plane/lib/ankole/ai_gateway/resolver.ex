defmodule Ankole.AIGateway.Resolver do
  @moduledoc """
  Resolves public model selectors into provider runtime maps.

  The resolver is the point where an agent-visible selector becomes a concrete
  provider id, provider kind, upstream model, and runtime settings. Provider
  modules only receive this resolved runtime map; they do not query agents or
  model profiles themselves.
  """

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ModelSelectors
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Providers
  alias Ankole.Principals

  @llm_aliases ~w(primary light heavy)

  @doc """
  Resolves the request `model` field for one agent and capability.

  LLM aliases use named profiles such as `primary`. Embedding and rerank accept
  `default`, explicit default bindings such as `embedding.default`, or explicit
  `provider_id/model` selectors.
  """
  @spec resolve_request_model(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_request_model(agent_uid, capability, request) do
    with {:ok, selector} <- model_selector(request) do
      resolve_model(agent_uid, capability, selector, request)
    end
  end

  defp resolve_model(agent_uid, "llm", selector, request) when selector in @llm_aliases do
    resolve_profile_model(agent_uid, "llm", selector, selector, request)
  end

  defp resolve_model(agent_uid, capability, selector, request)
       when capability in ["embedding", "rerank"] do
    case explicit_provider_selector(selector) do
      {:ok, provider_id, model} ->
        resolve_provider_model(agent_uid, capability, selector, provider_id, model, request)

      :error ->
        with {:ok, profile} <- ModelSelectors.default_profile(capability, selector) do
          resolve_profile_model(agent_uid, capability, selector, profile, request)
        end
    end
  end

  defp resolve_model(agent_uid, capability, selector, request) do
    case explicit_provider_selector(selector) do
      {:ok, provider_id, model} ->
        resolve_provider_model(agent_uid, capability, selector, provider_id, model, request)

      :error ->
        {:error, {:unknown_model_selector, capability, selector}}
    end
  end

  # Profile resolution keeps encrypted provider options in the control plane.
  # Workers get only AIGateway API keys and never receive upstream provider
  # secrets.
  defp resolve_profile_model(agent_uid, capability, selector, profile_name, request) do
    with {:ok, profile_capability} <- ModelProfiles.profile_capability(profile_name),
         ^capability <- profile_capability,
         {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, profile} <- ModelProfiles.get_model_profile(agent_uid, profile_name) do
      build_runtime(agent_uid, capability, selector, profile, request)
    else
      other when is_binary(other) -> {:error, {:model_profile_capability_mismatch, other}}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_provider_model(agent_uid, capability, selector, provider_id, model, request) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      build_runtime(
        agent_uid,
        capability,
        selector,
        %{"provider_id" => provider_id, "model" => model, "provider_options" => %{}},
        request
      )
    end
  end

  # This is the single runtime-map constructor for every selector style. Profile
  # selectors and explicit `provider/model` selectors must leave this module with
  # the same shape, otherwise provider preparation will drift by selector path.
  defp build_runtime(agent_uid, capability, selector, binding, request) do
    with {:ok, provider_id} <- binding_text(binding, "provider_id"),
         {:ok, model} <- binding_text(binding, "model"),
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         :ok <- Providers.ensure_capability_supported(provider_kind, capability),
         {:ok, provider_options} <-
           provider_options(provider.provider_kind, binding_provider_options(binding), request),
         {:ok, connection_options} <- ProviderConfigs.runtime_connection(provider) do
      runtime =
        %{
          "agent_uid" => agent_uid,
          "capability" => capability,
          "selector" => selector,
          "provider_id" => provider.provider_id,
          "provider_kind" => provider.provider_kind,
          "model" => model,
          "connection_options" => connection_options,
          "provider_options" => provider_options,
          "provider_metadata" => provider_metadata(provider_kind),
          "provider" => provider
        }

      {:ok, maybe_put_profile(runtime, binding)}
    end
  end

  defp model_selector(request) do
    case Map.get(request, "model") || Map.get(request, :model) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, :missing_model}
          selector -> {:ok, selector}
        end

      _value ->
        {:error, :missing_model}
    end
  end

  # Model-profile options are defaults. Top-level request `provider_options`
  # are per-call overrides, which keeps explicit `provider/model` selectors from
  # losing provider-specific knobs that profiles can already carry.
  defp provider_options(provider_kind, defaults, request) do
    with {:ok, overrides} <- request_provider_options(request) do
      options =
        defaults
        |> normalize_option_keys()
        |> Map.merge(overrides)

      with :ok <- Providers.validate_runtime_provider_options(provider_kind, options) do
        {:ok, options}
      end
    end
  end

  defp request_provider_options(request) when is_map(request) do
    case fetch_any(request, "provider_options") do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, %{}}
      {:ok, options} when is_map(options) -> {:ok, normalize_option_keys(options)}
      {:ok, _value} -> {:error, :invalid_provider_options}
    end
  end

  defp request_provider_options(_request), do: {:ok, %{}}

  defp normalize_option_keys(options) when is_map(options) do
    Map.new(options, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp binding_text(binding, key) when is_map(binding) do
    case fetch_any(binding, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:invalid_model_binding, key}}
    end
  end

  defp binding_provider_options(binding) when is_map(binding) do
    case fetch_any(binding, "provider_options") do
      {:ok, options} when is_map(options) -> options
      _value -> %{}
    end
  end

  defp maybe_put_profile(runtime, binding) do
    case fetch_any(binding, "profile") do
      {:ok, profile} when is_binary(profile) -> Map.put(runtime, "profile", profile)
      _value -> runtime
    end
  end

  defp fetch_any(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, String.to_atom(key))
    end
  end

  # Explicit selectors intentionally split only once. Provider ids cannot
  # contain `/`, while upstream model ids often do.
  defp explicit_provider_selector(selector) do
    case String.split(selector, "/", parts: 2) do
      [provider_id, model] when provider_id != "" and model != "" -> {:ok, provider_id, model}
      _parts -> :error
    end
  end

  defp provider_metadata(%Ankole.AIGateway.ProviderDefinition{} = provider_kind) do
    provider_kind
    |> Providers.projection()
    |> Map.take([
      "capabilities",
      "capability_specs",
      "settings"
    ])
  end
end
