defmodule Ankole.AIGateway.Resolver do
  @moduledoc """
  Resolves public model selectors into provider runtime maps.

  The resolver is the point where an agent-visible selector becomes a concrete
  provider id, provider kind, upstream model, connection options, and decrypted
  credential. Provider modules only receive this resolved runtime map; they do
  not query agents or model profiles themselves.
  """

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Providers
  alias Ankole.Principals

  @llm_aliases ~w(primary light heavy)
  @default_profiles %{
    "embedding" => "embedding",
    "rerank" => "rerank"
  }

  @doc """
  Resolves the request `model` field for one agent and capability.

  LLM aliases use named profiles such as `primary`. Embedding and rerank accept
  `default`, their first-class default profile names, or explicit
  `provider_id/model` selectors.
  """
  @spec resolve_request_model(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_request_model(agent_uid, capability, request) do
    with {:ok, selector} <- model_selector(request) do
      resolve_model(agent_uid, capability, selector)
    end
  end

  defp resolve_model(agent_uid, "llm", selector) when selector in @llm_aliases do
    resolve_profile_model(agent_uid, "llm", selector, selector)
  end

  defp resolve_model(agent_uid, capability, selector)
       when capability in ["embedding", "rerank"] do
    case explicit_provider_selector(selector) do
      {:ok, provider_id, model} ->
        resolve_provider_model(agent_uid, capability, selector, provider_id, model)

      :error ->
        with {:ok, profile} <- default_profile_selector(capability, selector) do
          resolve_profile_model(agent_uid, capability, selector, profile)
        end
    end
  end

  defp resolve_model(agent_uid, capability, selector) do
    case explicit_provider_selector(selector) do
      {:ok, provider_id, model} ->
        resolve_provider_model(agent_uid, capability, selector, provider_id, model)

      :error ->
        {:error, {:unknown_model_selector, capability, selector}}
    end
  end

  # Profile resolution keeps credential lookup in the control plane. Workers get
  # only AIGateway API keys and never receive upstream provider credentials.
  defp resolve_profile_model(agent_uid, capability, selector, profile_name) do
    with {:ok, profile} <- ModelProfiles.resolve_runtime_profile(agent_uid, profile_name),
         ^capability <- profile["capability"],
         {:ok, credential} <-
           profile |> Map.fetch!("provider") |> ProviderConfigs.plaintext_credential() do
      {:ok,
       %{
         "agent_uid" => profile["agent_uid"],
         "capability" => capability,
         "selector" => selector,
         "profile" => profile["profile"],
         "provider_id" => profile["provider_id"],
         "provider_kind" => profile["provider_kind"],
         "model" => profile["model"],
         "connection_options" => profile["connection_options"],
         "provider_options" => profile["provider_options"],
         "credential" => credential,
         "credential_mode" => profile["credential_mode"],
         "provider_metadata" => profile["provider_metadata"],
         "provider" => profile["provider"]
       }}
    else
      other when is_binary(other) -> {:error, {:model_profile_capability_mismatch, other}}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_provider_model(agent_uid, capability, selector, provider_id, model) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         :ok <- Providers.ensure_capability_supported(provider_kind, capability),
         {:ok, connection_options} <- ProviderConfigs.runtime_connection(provider),
         {:ok, credential} <- ProviderConfigs.plaintext_credential(provider) do
      {:ok,
       %{
         "agent_uid" => agent_uid,
         "capability" => capability,
         "selector" => selector,
         "provider_id" => provider.provider_id,
         "provider_kind" => provider.provider_kind,
         "model" => model,
         "connection_options" => connection_options,
         "provider_options" => %{},
         "credential" => credential,
         "credential_mode" => provider.credential_mode,
         "provider_metadata" => provider_metadata(provider_kind),
         "provider" => provider
       }}
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

  # Explicit selectors intentionally split only once. Provider ids cannot
  # contain `/`, while upstream model ids often do.
  defp explicit_provider_selector(selector) do
    case String.split(selector, "/", parts: 2) do
      [provider_id, model] when provider_id != "" and model != "" -> {:ok, provider_id, model}
      _parts -> :error
    end
  end

  defp default_profile_selector(capability, "default"),
    do: {:ok, Map.fetch!(@default_profiles, capability)}

  defp default_profile_selector(capability, selector) do
    case Map.fetch(@default_profiles, capability) do
      {:ok, ^selector} -> {:ok, selector}
      {:ok, _profile} -> {:error, {:unknown_model_selector, capability, selector}}
      :error -> {:error, {:unknown_model_selector, capability, selector}}
    end
  end

  defp provider_metadata(%Providers.Definition{} = provider_kind) do
    %{
      "provider_strategy" => provider_kind.provider_strategy,
      "capabilities" => provider_kind.capabilities,
      "endpoint_modes" => provider_kind.endpoint_modes,
      "model_catalog_policy" => provider_kind.model_catalog_policy
    }
  end
end
