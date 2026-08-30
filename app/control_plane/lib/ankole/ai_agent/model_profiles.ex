defmodule Ankole.AIAgent.ModelProfiles do
  @moduledoc """
  Agent-scoped model profile service.

  Profiles live under `agents.options["ai_agent"]["models"]`; provider rows own
  endpoint and encrypted option details. Embedding and rerank are not Agent
  profile slots: Brain owns those models instance-wide through `brain.*`
  AppConfigure keys.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.ImageModelCatalog
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ProviderDefinition
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.Resolver
  alias Ankole.Attrs
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  @profiles ~w(
    primary light heavy coding vision_fallback web_search web_fetch image_generate
  )

  # Capabilities a language-model Provider can run inside its own turn, so an
  # Agent can choose between its Provider and an Ankole capability profile.
  @provider_hosted_capabilities ~w(web_search image_generate)

  # Search and image generation default to the Provider: an Agent that never
  # chose a capability Provider should keep whatever its model already does.
  @provider_hosted_defaults %{
    "web_search" => true,
    "image_generate" => true
  }
  @required_profiles ~w(primary light heavy)
  @custom_profile_name ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @custom_profile_description_max_length 200
  @type profile :: String.t()

  @doc """
  Returns all supported model profile names.
  """
  @spec profiles() :: [String.t()]
  def profiles, do: @profiles

  @doc """
  Returns whether a name can identify an Agent custom model profile.
  """
  @spec custom_profile_name?(term()) :: boolean()
  def custom_profile_name?(profile) when is_binary(profile),
    do: profile not in @profiles and Regex.match?(@custom_profile_name, profile)

  def custom_profile_name?(_profile), do: false

  @doc """
  Returns the capability served by a profile slot.
  """
  @spec profile_capability(profile()) :: {:ok, String.t()} | {:error, :invalid_model_profile}
  def profile_capability(profile) do
    with {:ok, profile} <- normalize_profile(profile) do
      {:ok, capability_for_profile(profile)}
    end
  end

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
  Reads which capabilities this Agent leaves to its language-model Provider.

  A capability set to `true` is executed by the Provider inside its own model
  turn, and the Agent declares no Ankole tool or profile for it. A capability set
  to `false` uses the Agent's configured profile for that capability.

  Search and image generation default to `true`, so an Agent that never chose a
  search or image Provider uses whatever its model already does instead of
  silently having no capability. Compaction defaults to `false`, because Ankole
  can always compact locally.
  """
  @spec provider_hosted_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def provider_hosted_capabilities(agent_uid) do
    with {:ok, agent} <- fetch_agent(agent_uid) do
      {:ok, provider_hosted_from_agent(agent)}
    end
  end

  @doc """
  Returns whether one capability is left to the language-model Provider.
  """
  @spec provider_hosted?(map(), String.t()) :: boolean()
  def provider_hosted?(capabilities, capability)
      when is_map(capabilities) and is_binary(capability),
      do: Map.get(capabilities, capability, provider_hosted_default(capability)) == true

  defp provider_hosted_default(capability),
    do: Map.get(@provider_hosted_defaults, capability, true)

  @doc """
  Lists the configured custom LLM profile names and descriptions for an Agent.
  """
  @spec list_custom_model_profiles(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_custom_model_profiles(agent_uid) do
    with {:ok, profiles} <- get_model_profiles(agent_uid) do
      custom_profiles =
        profiles
        |> Enum.flat_map(fn
          {name, %{"description" => description}}
          when is_binary(description) and description != "" ->
            if custom_profile_name?(name),
              do: [%{"name" => name, "description" => description}],
              else: []

          {_name, _attrs} ->
            []
        end)
        |> Enum.sort_by(& &1["name"])

      {:ok, custom_profiles}
    end
  end

  @doc """
  Reads one configured custom LLM profile.
  """
  @spec get_custom_model_profile(String.t(), profile()) :: {:ok, map()} | {:error, term()}
  def get_custom_model_profile(agent_uid, profile) do
    with {:ok, profile} <- normalize_custom_profile(profile) do
      get_model_profile(agent_uid, profile)
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
      |> profile_with_fallback(profile)
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
  Sets which capabilities this Agent leaves to its language-model Provider.

  Only the named capabilities change, so one switch can be saved without
  restating the others.
  """
  @spec put_provider_hosted_capabilities(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_provider_hosted_capabilities(agent_uid, attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with %Agent{} = agent <- lock_agent(repo, agent_uid),
           {:ok, updates} <- normalize_provider_hosted_attrs(attrs),
           capabilities = Map.merge(provider_hosted_from_agent(agent), updates),
           options = put_provider_hosted_options(agent.options || %{}, capabilities),
           {:ok, _agent} <- update_agent_options(repo, agent, options) do
        {:ok, capabilities}
      else
        nil -> {:error, :agent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp normalize_provider_hosted_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      capability = to_string(key)

      cond do
        capability not in @provider_hosted_capabilities ->
          {:halt, {:error, {:unknown_provider_hosted_capability, capability}}}

        not is_boolean(value) ->
          {:halt, {:error, {:invalid_provider_hosted_capability, capability}}}

        true ->
          {:cont, {:ok, Map.put(acc, capability, value)}}
      end
    end)
  end

  defp put_provider_hosted_options(options, capabilities) do
    ai_agent =
      case Map.get(options, "ai_agent") do
        value when is_map(value) -> value
        _value -> %{}
      end

    Map.put(options, "ai_agent", Map.put(ai_agent, "provider_hosted", capabilities))
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

  @doc """
  Resolves the frozen model reference used by Worker turns.

  `input_modalities` describes only the selected model. A text-only model gets
  a separate vision fallback reference only when that profile resolves to a
  model that accepts image input directly.
  """
  @spec resolve_runtime_model_ref(String.t(), profile()) :: {:ok, map()} | {:error, term()}
  def resolve_runtime_model_ref(agent_uid, profile) do
    with {:ok, runtime_profile} <- resolve_runtime_profile(agent_uid, profile) do
      model_ref = model_ref_from_runtime_profile(runtime_profile)
      {:ok, maybe_put_vision_fallback_model_ref(model_ref, agent_uid)}
    end
  end

  @doc "Returns the modalities that the model and its frozen fallback can handle."
  @spec effective_input_modalities(map()) :: [String.t()]
  def effective_input_modalities(model_ref) when is_map(model_ref) do
    direct = Map.get(model_ref, "input_modalities", ["text"])

    fallback_modalities =
      model_ref
      |> get_in(["vision_fallback_model_ref", "input_modalities"])
      |> List.wrap()

    if "image" in direct or "image" in fallback_modalities do
      Enum.uniq(direct ++ ["image"])
    else
      direct
    end
  end

  def effective_input_modalities(_model_ref), do: ["text"]

  @doc false
  @spec complete_legacy_model_ref(String.t(), map()) :: map()
  def complete_legacy_model_ref(agent_uid, model_ref)
      when is_binary(agent_uid) and is_map(model_ref) do
    model_ref
    |> Map.delete("vision_fallback_model_ref")
    |> Map.put("input_modalities", input_modalities_for_frozen_model_ref(model_ref))
    |> maybe_put_vision_fallback_model_ref(agent_uid)
  end

  defp input_modalities_for_frozen_model_ref(%{
         "provider_id" => provider_id,
         "provider_kind" => provider_kind,
         "model" => model
       })
       when is_binary(provider_id) and is_binary(provider_kind) and is_binary(model) do
    case ProviderConfigs.fetch_active_provider(provider_id) do
      {:ok, %Provider{provider_kind: ^provider_kind} = provider} ->
        input_modalities(provider, model)

      _unavailable_or_changed ->
        ["text"]
    end
  end

  defp input_modalities_for_frozen_model_ref(_model_ref), do: ["text"]

  @doc false
  @spec model_ref_from_runtime_profile(map()) :: map()
  def model_ref_from_runtime_profile(runtime_profile) when is_map(runtime_profile) do
    %{
      "profile" => runtime_profile["profile"],
      "provider_id" => runtime_profile["provider_id"],
      "provider_kind" => runtime_profile["provider_kind"],
      "model" => runtime_profile["model"],
      "input_modalities" => input_modalities_for_runtime_profile(runtime_profile),
      "provider_options" => Map.get(runtime_profile, "provider_options", %{}),
      "supports_parallel_tool_calls" => supports_parallel_tool_calls?(runtime_profile)
    }
    |> Attrs.maybe_put("context_length", Map.get(runtime_profile, "context_length"))
    |> Attrs.maybe_put(
      "max_completion_tokens",
      max_completion_tokens_for_runtime_profile(runtime_profile)
    )
  end

  defp maybe_put_vision_fallback_model_ref(model_ref, agent_uid) do
    if "image" in Map.get(model_ref, "input_modalities", []) do
      model_ref
    else
      case resolve_runtime_profile(agent_uid, "vision_fallback") do
        {:ok, fallback_runtime_profile} ->
          fallback_ref = model_ref_from_runtime_profile(fallback_runtime_profile)

          if "image" in fallback_ref["input_modalities"] do
            Map.put(model_ref, "vision_fallback_model_ref", fallback_ref)
          else
            model_ref
          end

        {:error, _reason} ->
          model_ref
      end
    end
  end

  defp input_modalities_for_runtime_profile(%{
         "provider" => %Provider{} = provider,
         "model" => model
       }),
       do: input_modalities(provider, model)

  defp input_modalities_for_runtime_profile(%{"provider_id" => provider_id, "model" => model})
       when is_binary(provider_id) do
    case ProviderConfigs.fetch_active_provider(provider_id) do
      {:ok, provider} -> input_modalities(provider, model)
      {:error, _reason} -> ["text"]
    end
  end

  defp input_modalities_for_runtime_profile(_runtime_profile), do: ["text"]

  defp input_modalities(%Provider{} = provider, model) when is_binary(model) do
    case ModelMetadata.model_metadata(provider, model) do
      {:ok, %{"architecture" => %{"input_modalities" => [_ | _] = modalities}}} ->
        Enum.map(modalities, &to_string/1)

      _metadata ->
        ["text"]
    end
  end

  defp input_modalities(_provider, _model), do: ["text"]

  defp max_completion_tokens_for_runtime_profile(%{
         "provider" => %Provider{} = provider,
         "model" => model
       }),
       do: max_completion_tokens(provider, model)

  defp max_completion_tokens_for_runtime_profile(%{
         "provider_id" => provider_id,
         "model" => model
       })
       when is_binary(provider_id) do
    case ProviderConfigs.fetch_active_provider(provider_id) do
      {:ok, provider} -> max_completion_tokens(provider, model)
      {:error, _reason} -> nil
    end
  end

  defp max_completion_tokens_for_runtime_profile(_runtime_profile), do: nil

  defp max_completion_tokens(%Provider{} = provider, model) when is_binary(model) do
    case ModelMetadata.model_metadata(provider, model) do
      {:ok, %{"top_provider" => %{"max_completion_tokens" => value}}} -> positive_integer(value)
      _metadata -> nil
    end
  end

  defp max_completion_tokens(_provider, _model), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp supports_parallel_tool_calls?(%{"provider_kind" => provider_kind}) do
    with {:ok, provider} <- Providers.fetch(provider_kind),
         {:ok, capability} <- ProviderDefinition.capability(provider, :language_model) do
      capability.supports_parallel_tool_calls?
    else
      _error -> false
    end
  end

  defp supports_parallel_tool_calls?(_runtime_profile), do: false

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

  defp provider_hosted_from_agent(%Agent{options: options}) when is_map(options) do
    case get_in(options, ["ai_agent", "provider_hosted"]) do
      capabilities when is_map(capabilities) -> capabilities
      _value -> %{}
    end
  end

  defp provider_hosted_from_agent(%Agent{}), do: %{}

  defp profile_result(nil, _profile), do: {:error, :model_profile_not_configured}
  defp profile_result(%{} = attrs, profile), do: {:ok, Map.put(attrs, "profile", profile)}
  defp profile_result(_value, _profile), do: {:error, :invalid_model_profile}

  defp profile_with_fallback(profiles, "coding") do
    case Map.get(profiles, "coding") do
      %{} = profile -> profile
      _value -> profiles |> Map.get("heavy") |> maybe_mark_fallback("heavy")
    end
  end

  defp profile_with_fallback(profiles, "light") do
    case Map.get(profiles, "light") do
      %{} = profile -> profile
      _value -> profiles |> Map.get("primary") |> maybe_mark_fallback("primary")
    end
  end

  defp profile_with_fallback(profiles, profile), do: Map.get(profiles, profile)

  defp maybe_mark_fallback(%{} = profile, fallback_profile),
    do: Map.put(profile, "fallback_profile", fallback_profile)

  defp maybe_mark_fallback(value, _fallback_profile), do: value

  defp normalize_profile(profile) when is_binary(profile) do
    profile = String.trim(profile)
    fixed_profile = String.downcase(profile)

    cond do
      fixed_profile in @profiles -> {:ok, fixed_profile}
      custom_profile_name?(profile) -> {:ok, profile}
      true -> {:error, :invalid_model_profile}
    end
  end

  defp normalize_profile(_profile), do: {:error, :invalid_model_profile}

  defp normalize_custom_profile(profile) do
    with {:ok, profile} <- normalize_profile(profile),
         true <- custom_profile_name?(profile) do
      {:ok, profile}
    else
      _invalid -> {:error, :invalid_custom_model_profile}
    end
  end

  defp normalize_profile_attrs(profile, nil) when profile in @required_profiles,
    do: {:error, :model_profile_required}

  defp normalize_profile_attrs(_profile, nil), do: {:ok, nil}
  defp normalize_profile_attrs(_profile, %{} = attrs) when map_size(attrs) == 0, do: {:ok, nil}

  defp normalize_profile_attrs(profile, attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with {:ok, description} <- normalize_profile_description(profile, attrs),
         {:ok, normalized_profile} <- normalize_aigateway_profile(profile, attrs) do
      {:ok, maybe_put_description(normalized_profile, description)}
    end
  end

  defp normalize_profile_attrs(_profile, _attrs), do: {:error, :invalid_model_profile}

  defp normalize_aigateway_profile(profile, attrs) do
    with {:ok, provider_id} <- required_text(attrs, "provider_id"),
         {:ok, model} <- required_text(attrs, "model"),
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         :ok <- validate_profile_provider(profile, provider_kind),
         {:ok, provider_options} <-
           normalize_provider_options(Map.get(attrs, "provider_options", %{})),
         {:ok, context_length} <- normalize_context_length(Map.get(attrs, "context_length")),
         :ok <- validate_provider_options(provider, provider_options),
         :ok <- validate_profile_model(profile, provider, model) do
      profile = %{
        "provider_id" => provider.provider_id,
        "model" => model,
        "provider_options" => provider_options
      }

      {:ok, maybe_put_context_length(profile, context_length)}
    end
  end

  defp validate_profile_provider(profile, %Ankole.AIGateway.ProviderDefinition{} = provider_kind) do
    capability = capability_for_profile(profile)

    case Providers.supports_capability?(provider_kind, capability) do
      true -> :ok
      false -> {:error, {:provider_kind_missing_capability, capability}}
    end
  end

  defp validate_profile_model("image_generate", provider, model),
    do: ImageModelCatalog.validate_configured_model(provider, model)

  defp validate_profile_model(_profile, _provider, _model), do: :ok

  defp normalize_provider_options(options) when is_map(options), do: {:ok, options}
  defp normalize_provider_options(_options), do: {:error, :invalid_provider_options}

  defp normalize_context_length(nil), do: {:ok, nil}

  defp normalize_context_length(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_context_length(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _value -> {:error, :invalid_context_length}
    end
  end

  defp normalize_context_length(_value), do: {:error, :invalid_context_length}

  defp maybe_put_context_length(profile, nil), do: profile

  defp maybe_put_context_length(profile, context_length),
    do: Map.put(profile, "context_length", context_length)

  defp normalize_profile_description(profile, attrs) do
    if custom_profile_name?(profile) do
      with {:ok, description} <- required_text(attrs, "description"),
           true <- String.length(description) <= @custom_profile_description_max_length do
        {:ok, description}
      else
        false ->
          {:error,
           {:custom_model_profile_description_too_long, @custom_profile_description_max_length}}

        {:error, _reason} = error ->
          error
      end
    else
      case Map.has_key?(attrs, "description") do
        true -> {:error, :fixed_model_profile_description_not_allowed}
        false -> {:ok, nil}
      end
    end
  end

  defp maybe_put_description(profile, nil), do: profile

  defp maybe_put_description(profile, description),
    do: Map.put(profile, "description", description)

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

  defp capability_for_profile("web_search"), do: "web_search"
  defp capability_for_profile("web_fetch"), do: "web_fetch"
  defp capability_for_profile("image_generate"), do: "image_generate"
  defp capability_for_profile(_profile), do: "llm"

  defp normalize_uid!(uid) do
    {:ok, uid} = Principals.normalize_uid(uid)
    uid
  end
end
