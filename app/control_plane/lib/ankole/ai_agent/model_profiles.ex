defmodule Ankole.AIAgent.ModelProfiles do
  @moduledoc """
  Agent-scoped LLM model profile service.

  Profiles live under `agents.options["ai_agent"]["models"]`; provider rows own
  endpoint and credential details.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.LlmProviders
  alias Ankole.AIAgent.LlmProviders.Provider
  alias Ankole.AIAgent.ProviderSources
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  # Fixed slots an agent can bind a model to. `primary`/`light`/`heavy` are the
  # everyday tiers and must be configured for the agent to run real turns;
  # `codex` is optional and only meaningful on Codex-compatible provider sources,
  # so a missing `codex` returns a typed error rather than blocking startup.
  @profiles ~w(primary light heavy codex)
  @required_profiles ~w(primary light heavy)

  @type profile :: String.t()

  @doc """
  Returns all supported model profile names.
  """
  @spec profiles() :: [String.t()]
  def profiles, do: @profiles

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
  Reads one model profile. Missing optional `codex` returns a typed error.
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
    with {:ok, profile} <- get_model_profile(agent_uid, profile),
         {:ok, provider} <- LlmProviders.fetch_active_provider(profile["provider_id"]),
         {:ok, source} <- ProviderSources.fetch(provider.provider_source),
         :ok <- validate_profile_source(profile["profile"], provider),
         :ok <-
           ProviderSources.validate_runtime_provider_options(
             provider.provider_source,
             profile["provider_options"] || %{}
           ),
         {:ok, connection_options} <- LlmProviders.runtime_connection(provider) do
      {:ok,
       %{
         "agent_uid" => normalize_uid!(agent_uid),
         "profile" => profile["profile"],
         "provider_id" => provider.provider_id,
         "provider_source" => provider.provider_source,
         "model" => profile["model"],
         "connection_options" => connection_options,
         "provider_options" => profile["provider_options"] || %{},
         "credential_mode" => provider.credential_mode,
         "source_metadata" => %{
           "adapter" => source.adapter,
           "adapter_strategy" => source.adapter_strategy,
           "codex_compatible" => source.codex_compatible?
         },
         "provider" => provider
       }}
    end
  end

  @doc """
  Projects Codex capability for an agent.
  """
  @spec codex_capability(String.t()) :: {:ok, map()} | {:error, term()}
  def codex_capability(agent_uid) do
    case resolve_runtime_profile(agent_uid, "codex") do
      {:ok, profile} ->
        {:ok,
         %{
           "available" => true,
           "provider_id" => profile["provider_id"],
           "model" => profile["model"]
         }}

      {:error, :model_profile_not_configured} ->
        {:ok, %{"available" => false, "reason" => "model_profile_not_configured"}}

      {:error, reason} ->
        {:ok, %{"available" => false, "reason" => inspect(reason)}}
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

  defp profile_result(nil, "codex"), do: {:error, :model_profile_not_configured}

  defp profile_result(nil, profile) when profile in @required_profiles,
    do: {:error, :model_profile_not_configured}

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

  defp normalize_profile_attrs("codex", nil), do: {:ok, nil}
  defp normalize_profile_attrs("codex", %{} = attrs) when map_size(attrs) == 0, do: {:ok, nil}

  defp normalize_profile_attrs(profile, attrs) when is_map(attrs) do
    attrs = normalize_external_attrs(attrs)

    with {:ok, provider_id} <- required_text(attrs, "provider_id"),
         {:ok, model} <- required_text(attrs, "model"),
         {:ok, provider} <- LlmProviders.fetch_active_provider(provider_id),
         :ok <- validate_profile_source(profile, provider),
         provider_options <- Map.get(attrs, "provider_options", %{}),
         :ok <- validate_provider_options(provider, provider_options) do
      {:ok,
       %{
         "provider_id" => provider.provider_id,
         "model" => model,
         "provider_options" => provider_options
       }}
    end
  end

  defp normalize_profile_attrs(_profile, nil), do: {:error, :model_profile_required}
  defp normalize_profile_attrs(_profile, _attrs), do: {:error, :invalid_model_profile}

  defp validate_profile_source("codex", %Provider{provider_source: source}) do
    case ProviderSources.codex_compatible?(source) do
      true -> :ok
      false -> {:error, :codex_incompatible_provider_source}
    end
  end

  defp validate_profile_source(_profile, %Provider{}), do: :ok

  defp validate_provider_options(%Provider{provider_source: source}, options)
       when is_map(options),
       do: ProviderSources.validate_runtime_provider_options(source, options)

  defp validate_provider_options(_provider, _options), do: {:error, :invalid_provider_options}

  defp put_profile_options(options, "codex", nil) do
    {:ok, replace_models(options, &Map.delete(&1, "codex"))}
  end

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

  defp normalize_uid!(uid) do
    {:ok, uid} = Principals.normalize_uid(uid)
    uid
  end
end
