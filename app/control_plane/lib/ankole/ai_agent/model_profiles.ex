defmodule Ankole.AIAgent.ModelProfiles do
  @moduledoc """
  Agent-scoped model profile service.

  Profiles live under `agents.options["ai_agent"]["models"]`; provider rows own
  endpoint and encrypted option details. LLM tiers and default embedding/rerank models
  are all first-class profile slots.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Resolver
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  @profiles ~w(primary light heavy embedding rerank)
  @required_profiles ~w(primary light heavy)

  @type profile :: String.t()

  @doc """
  Returns all supported model profile names.
  """
  @spec profiles() :: [String.t()]
  def profiles, do: @profiles

  @doc """
  Returns the capability served by a profile slot.
  """
  @spec profile_capability(profile()) :: {:ok, String.t()} | {:error, :invalid_model_profile}
  def profile_capability(profile) when profile in @profiles do
    {:ok, capability_for_profile(profile)}
  end

  def profile_capability(_profile), do: {:error, :invalid_model_profile}

  @doc """
  Reads all model profiles for an agent.
  """
  @spec get_model_profiles(String.t()) :: {:ok, map()} | {:error, term()}
  def get_model_profiles(agent_uid) do
    with {:ok, agent} <- fetch_agent(agent_uid) do
      {:ok, profiles_from_agent(agent)}
    end
  end

  @doc """
  Reads one model profile.
  """
  @spec get_model_profile(String.t(), profile()) :: {:ok, map()} | {:error, term()}
  def get_model_profile(agent_uid, profile) do
    with {:ok, agent} <- fetch_agent(agent_uid),
         {:ok, profile} <- normalize_profile(profile) do
      agent
      |> profiles_from_agent()
      |> Map.get(profile)
      |> profile_result(profile)
    end
  end

  @doc """
  Updates one model profile after validating the referenced provider and
  provider options.
  """
  @spec put_model_profile(String.t(), profile(), map() | nil) ::
          {:ok, %{agent: Agent.t(), profile: map() | nil}} | {:error, term()}
  def put_model_profile(agent_uid, profile, attrs) do
    Repo.transact(fn repo ->
      with %Agent{} = agent <- lock_agent(repo, agent_uid),
           {:ok, profile} <- normalize_profile(profile),
           {:ok, normalized_profile} <- normalize_profile_attrs(profile, attrs),
           {:ok, options} <-
             put_profile_options(agent.options || %{}, profile, normalized_profile),
           {:ok, agent} <- update_agent_options(repo, agent, options) do
        {:ok, %{agent: agent, profile: normalized_profile}}
      else
        nil -> {:error, :agent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Resolves the authoritative provider/model/options for one agent profile.
  """
  @spec resolve_runtime_profile(String.t(), profile()) :: {:ok, map()} | {:error, term()}
  def resolve_runtime_profile(agent_uid, profile) do
    with {:ok, profile} <- normalize_profile(profile),
         {:ok, capability} <- profile_capability(profile) do
      selector = Ankole.AIGateway.ModelSelectors.public_selector(capability, profile)
      Resolver.resolve_request_model(agent_uid, capability, %{"model" => selector})
    end
  end

  defp fetch_agent(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      case Repo.get(Agent, agent_uid) do
        %Agent{} = agent -> {:ok, agent}
        nil -> {:error, :agent_not_found}
      end
    end
  end

  defp lock_agent(repo, agent_uid) do
    normalized_uid = normalize_uid!(agent_uid)

    Agent
    |> where([agent], agent.uid == ^normalized_uid)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp update_agent_options(repo, agent, options) do
    agent
    |> Agent.changeset(%{options: options})
    |> repo.update()
  end

  defp profiles_from_agent(%Agent{options: options}) when is_map(options) do
    case get_in(options, ["ai_agent", "models"]) do
      models when is_map(models) -> models
      _value -> %{}
    end
  end

  defp profile_result(nil, _profile), do: {:error, :model_profile_not_configured}
  defp profile_result(%{} = attrs, profile), do: {:ok, Map.put(attrs, "profile", profile)}
  defp profile_result(_value, _profile), do: {:error, :invalid_model_profile}

  defp normalize_profile(profile) when is_binary(profile) do
    profile = profile |> String.trim() |> String.downcase()

    case profile in @profiles do
      true -> {:ok, profile}
      false -> {:error, :invalid_model_profile}
    end
  end

  defp normalize_profile(_profile), do: {:error, :invalid_model_profile}

  defp normalize_profile_attrs(profile, nil) when profile in @required_profiles,
    do: {:error, :model_profile_required}

  defp normalize_profile_attrs(_profile, nil), do: {:ok, nil}
  defp normalize_profile_attrs(_profile, %{} = attrs) when map_size(attrs) == 0, do: {:ok, nil}

  defp normalize_profile_attrs(profile, attrs) when is_map(attrs) do
    attrs = normalize_external_attrs(attrs)

    with {:ok, provider_id} <- required_text(attrs, "provider_id"),
         {:ok, model} <- required_text(attrs, "model"),
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         :ok <- validate_profile_provider(profile, provider_kind),
         {:ok, provider_options} <-
           normalize_provider_options(Map.get(attrs, "provider_options", %{})),
         :ok <- validate_provider_options(provider, provider_options) do
      {:ok,
       %{
         "provider_id" => provider.provider_id,
         "model" => model,
         "provider_options" => provider_options
       }}
    end
  end

  defp normalize_profile_attrs(_profile, _attrs), do: {:error, :invalid_model_profile}

  defp validate_profile_provider(profile, %Ankole.AIGateway.ProviderDefinition{} = provider_kind) do
    capability = capability_for_profile(profile)

    case Providers.supports_capability?(provider_kind, capability) do
      true -> :ok
      false -> {:error, {:provider_kind_missing_capability, capability}}
    end
  end

  defp normalize_provider_options(options) when is_map(options), do: {:ok, options}
  defp normalize_provider_options(_options), do: {:error, :invalid_provider_options}

  defp validate_provider_options(%Provider{provider_kind: provider_kind}, options)
       when is_map(options),
       do: Providers.validate_runtime_provider_options(provider_kind, options)

  defp validate_provider_options(_provider, _options), do: {:error, :invalid_provider_options}

  defp put_profile_options(options, profile, nil) when profile not in @required_profiles do
    {:ok, replace_models(options, &Map.delete(&1, profile))}
  end

  defp put_profile_options(_options, profile, nil) when profile in @required_profiles,
    do: {:error, :model_profile_required}

  defp put_profile_options(options, profile, profile_attrs) do
    {:ok, replace_models(options, &Map.put(&1, profile, profile_attrs))}
  end

  defp replace_models(options, fun) do
    ai_agent =
      case Map.get(options, "ai_agent") do
        value when is_map(value) -> value
        _value -> %{}
      end

    models =
      case Map.get(ai_agent, "models") do
        value when is_map(value) -> value
        _value -> %{}
      end

    Map.put(options, "ai_agent", Map.put(ai_agent, "models", fun.(models)))
  end

  defp normalize_external_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp required_text(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          value -> {:ok, value}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp capability_for_profile("embedding"), do: "embedding"
  defp capability_for_profile("rerank"), do: "rerank"
  defp capability_for_profile(_profile), do: "llm"

  defp normalize_uid!(uid) do
    {:ok, uid} = Principals.normalize_uid(uid)
    uid
  end
end
