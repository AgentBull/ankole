defmodule Ankole.AIGateway.ModelProfiles do
  @moduledoc """
  Site, Pod, Agent, and system Principal model profile configuration and inheritance.

  Agent overrides live under `agents.options["ai_agent"]`; system Principal,
  Pod, and Site overrides use AppConfigure rows. Runtime reads merge each slot across those
  layers before applying the coding and light fallbacks.
  """

  alias Ankole.AIGateway.ImageModelCatalog
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
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
  @pod_profiles @profiles ++ ["rerank"]
  @provider_hosted_capabilities ~w(web_search image_generate)
  @provider_hosted_defaults %{
    "web_search" => true,
    "image_generate" => true
  }
  @custom_profile_name ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @custom_profile_description_max_length 200
  @type scope :: :tenant | :global
  @type profile :: String.t()

  def agent_profiles, do: @profiles
  def pod_profiles, do: @pod_profiles
  def provider_hosted_capabilities, do: @provider_hosted_capabilities

  @doc "Declares the Pod and Site model profile and Provider-hosted keys."
  @spec definitions() :: [Definition.t()]
  def definitions do
    Enum.map(@pod_profiles, fn profile ->
      Definition.new!(
        key: profile_key(profile),
        encrypted: false,
        scope: :tenant,
        schema: model_profile_schema(),
        default_value: nil,
        console_writable: false,
        description: "Pod or Site #{profile} model profile override."
      )
    end) ++
      Enum.map(@provider_hosted_capabilities, fn capability ->
        Definition.new!(
          key: provider_hosted_key(capability),
          encrypted: false,
          scope: :tenant,
          schema: Schema.boolean(),
          default_value: true,
          console_writable: false,
          description: "Whether #{capability} stays hosted by the language-model Provider."
        )
      end)
  end

  @doc "Returns whether a name can identify an Agent custom model profile."
  @spec custom_profile_name?(term()) :: boolean()
  def custom_profile_name?(profile) when is_binary(profile),
    do: profile not in @profiles and Regex.match?(@custom_profile_name, profile)

  def custom_profile_name?(_profile), do: false

  @doc "Validates and normalizes one standalone custom LLM profile."
  @spec normalize_custom_model_profile(profile(), map()) :: {:ok, map()} | {:error, term()}
  def normalize_custom_model_profile(profile, attrs) do
    with {:ok, profile} <- normalize_custom_profile(profile),
         {:ok, %{} = normalized} <- normalize_profile_attrs(profile, attrs) do
      {:ok, normalized}
    else
      {:ok, nil} -> {:error, :invalid_custom_model_profile}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the capability served by an Agent profile slot."
  @spec profile_capability(profile()) :: {:ok, String.t()} | {:error, :invalid_model_profile}
  def profile_capability(profile) do
    with {:ok, profile} <- normalize_profile(profile) do
      {:ok, capability_for_profile(profile)}
    end
  end

  @doc "Reads the final effective profiles for an Agent, Human, or system Principal."
  @spec get_model_profiles(String.t()) :: {:ok, map()} | {:error, term()}
  def get_model_profiles(subject_uid) do
    with {:ok, configuration} <- model_profile_configuration(subject_uid) do
      {:ok, bare_profiles(configuration.effective)}
    end
  end

  @doc "Reads one final effective profile for an Agent, Human, or system Principal."
  @spec get_model_profile(String.t(), profile()) :: {:ok, map()} | {:error, term()}
  def get_model_profile(subject_uid, profile) do
    with {:ok, profile} <- normalize_profile(profile),
         {:ok, configuration} <- model_profile_configuration(subject_uid) do
      configuration.effective
      |> Map.get(profile, empty_entry(profile))
      |> profile_result(profile)
    end
  end

  @doc "Reads one Pod effective slot for any Principal, including Agent rerank calls."
  @spec get_pod_model_profile(String.t(), profile()) :: {:ok, map()} | {:error, term()}
  def get_pod_model_profile(subject_uid, profile) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid),
         {:ok, _principal} <- Principals.get_principal(subject_uid),
         {:ok, profile} <- normalize_pod_profile(profile),
         {:ok, configuration} <- defaults_configuration(:tenant) do
      configuration.effective
      |> Map.fetch!(profile)
      |> profile_result(profile)
    end
  end

  @doc "Reads overrides, same-slot inherited values, and final effective values."
  @spec model_profile_configuration(String.t()) :: {:ok, map()} | {:error, term()}
  def model_profile_configuration(subject_uid) do
    with {:ok, subject_uid} <- Principals.normalize_uid(subject_uid) do
      case Principals.get_principal(subject_uid) do
        {:ok, %{type: :agent}} -> agent_configuration(subject_uid)
        {:ok, %{type: :human}} -> defaults_configuration(:tenant)
        {:ok, %{type: :system}} -> system_model_profile_configuration(subject_uid)
        {:ok, _principal} -> {:error, :invalid_model_profile_subject}
        {:error, :not_found} -> {:error, :principal_not_found}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc "Reads a registered system Principal's overrides and Pod/Site inheritance."
  def system_model_profile_configuration(uid) do
    with {:ok, _principal} <- Principals.system_principal(uid),
         {:ok, current} <- read_profile_layer({:system, uid}, @pod_profiles),
         {:ok, tenant} <- read_profile_layer(:tenant, @pod_profiles),
         {:ok, global} <- read_profile_layer(:global, @pod_profiles),
         {:ok, hosted} <- hosted_configuration(nil, :tenant) do
      inherited = Map.merge(global, tenant)

      {:ok,
       %{
         overrides: entry_values(current),
         inherited: complete_inherited(inherited, @pod_profiles),
         effective: effective_entries(Map.merge(inherited, current), @pod_profiles),
         provider_hosted: hosted
       }}
    end
  end

  @doc "Stores or clears a registered system Principal's fixed-slot override."
  def put_system_model_profile(uid, profile, attrs) do
    with {:ok, _principal} <- Principals.system_principal(uid),
         {:ok, profile} <- normalize_pod_profile(profile),
         {:ok, normalized} <- normalize_default_profile_attrs(profile, attrs),
         {:ok, _value} <- put_default_value({:system, uid}, profile_key(profile), normalized) do
      {:ok, %{profile: normalized}}
    end
  end

  @doc "Reads a Pod or Site configuration without mixing the three read contracts."
  @spec defaults_model_profile_configuration(scope()) :: {:ok, map()} | {:error, term()}
  def defaults_model_profile_configuration(scope) when scope in [:tenant, :global],
    do: defaults_configuration(scope)

  @doc "Stores or clears one Pod or Site fixed-slot override."
  @spec put_default_model_profile(scope(), profile(), map() | nil) ::
          {:ok, %{profile: map() | nil}} | {:error, term()}
  def put_default_model_profile(scope, profile, attrs) when scope in [:tenant, :global] do
    with {:ok, profile} <- normalize_pod_profile(profile),
         {:ok, normalized} <- normalize_default_profile_attrs(profile, attrs),
         {:ok, _value} <- put_default_value(scope, profile_key(profile), normalized) do
      {:ok, %{profile: normalized}}
    end
  end

  @doc "Stores or clears Pod or Site Provider-hosted overrides."
  @spec put_default_provider_hosted_capabilities(scope(), map()) ::
          {:ok, map()} | {:error, term()}
  def put_default_provider_hosted_capabilities(scope, attrs)
      when scope in [:tenant, :global] and is_map(attrs) do
    with {:ok, updates} <- normalize_provider_hosted_attrs(attrs),
         {:ok, _values} <- put_provider_hosted_defaults(scope, updates),
         {:ok, configuration} <- defaults_configuration(scope) do
      {:ok, bare_provider_hosted(configuration.provider_hosted.effective)}
    end
  end

  @doc "Reads effective Provider-hosted capabilities for any supported subject."
  @spec provider_hosted_capabilities(String.t()) :: {:ok, map()} | {:error, term()}
  def provider_hosted_capabilities(subject_uid) do
    with {:ok, configuration} <- model_profile_configuration(subject_uid) do
      {:ok, bare_provider_hosted(configuration.provider_hosted.effective)}
    end
  end

  @doc "Returns whether one capability is left to the language-model Provider."
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
  Updates one model profile after validating the referenced provider and
  provider options. A nil or empty value removes the override at any slot.
  """
  @spec put_model_profile(String.t(), profile(), map() | nil) ::
          {:ok, %{agent: Agent.t(), profile: map() | nil}} | {:error, term()}
  def put_model_profile(agent_uid, profile, attrs) do
    agent_uid = normalize_uid!(agent_uid)
    Repo.transact_top_level(fn -> put_profile_locked(agent_uid, profile, attrs) end)
  end

  defp put_profile_locked(agent_uid, profile, attrs) do
    with %Agent{} = agent <- lock_agent(agent_uid),
         {:ok, profile} <- normalize_profile(profile),
         {:ok, normalized_profile} <- normalize_profile_attrs(profile, attrs),
         {:ok, options} <-
           put_profile_options(agent.options || %{}, profile, normalized_profile),
         {:ok, agent} <- update_agent_options(agent, options) do
      {:ok, %{agent: agent, profile: normalized_profile}}
    else
      nil -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Sets or clears Agent Provider-hosted capability overrides."
  @spec put_provider_hosted_capabilities(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def put_provider_hosted_capabilities(agent_uid, attrs) when is_map(attrs) do
    agent_uid = normalize_uid!(agent_uid)
    Repo.transact_top_level(fn -> put_provider_hosted_locked(agent_uid, attrs) end)
  end

  defp put_provider_hosted_locked(agent_uid, attrs) do
    with %Agent{} = agent <- lock_agent(agent_uid),
         {:ok, updates} <- normalize_provider_hosted_attrs(attrs),
         capabilities =
           agent
           |> provider_hosted_from_agent()
           |> Map.merge(updates)
           |> Enum.reject(fn {_key, value} -> is_nil(value) end)
           |> Map.new(),
         options = put_provider_hosted_options(agent.options || %{}, capabilities),
         {:ok, _agent} <- update_agent_options(agent, options),
         {:ok, effective} <- provider_hosted_capabilities(agent_uid) do
      {:ok, effective}
    else
      nil -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_provider_hosted_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      capability = to_string(key)

      cond do
        capability not in @provider_hosted_capabilities ->
          {:halt, {:error, {:unknown_provider_hosted_capability, capability}}}

        not (is_boolean(value) or is_nil(value)) ->
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

  @spec model_ref_from_runtime_profile(map()) :: map()
  defp model_ref_from_runtime_profile(runtime_profile) when is_map(runtime_profile) do
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

  defp agent_configuration(agent_uid) do
    with {:ok, agent} <- fetch_agent(agent_uid),
         {:ok, tenant} <- read_profile_layer(:tenant, @profiles),
         {:ok, global} <- read_profile_layer(:global, @profiles),
         {:ok, hosted} <- hosted_configuration(provider_hosted_from_agent(agent), :agent) do
      inherited = Map.merge(global, tenant)
      overrides = profiles_from_agent(agent)

      direct =
        Map.merge(inherited, value_entries(overrides, :agent))

      profile_order =
        @profiles ++
          (overrides |> Map.keys() |> Enum.filter(&custom_profile_name?/1) |> Enum.sort())

      {:ok,
       %{
         overrides: overrides,
         inherited: complete_inherited(inherited, @profiles),
         effective: effective_entries(direct, profile_order),
         provider_hosted: hosted
       }}
    end
  end

  defp defaults_configuration(scope) do
    with {:ok, current} <- read_profile_layer(scope, @pod_profiles),
         {:ok, inherited} <- inherited_profile_layer(scope),
         {:ok, hosted} <- hosted_configuration(nil, scope) do
      direct = Map.merge(inherited, current)

      {:ok,
       %{
         overrides: entry_values(current),
         inherited: complete_inherited(inherited, @pod_profiles),
         effective: effective_entries(direct, @pod_profiles),
         provider_hosted: hosted
       }}
    end
  end

  defp inherited_profile_layer(:tenant), do: read_profile_layer(:global, @pod_profiles)
  defp inherited_profile_layer(:global), do: {:ok, %{}}

  defp read_profile_layer(scope, profiles) do
    Enum.reduce_while(profiles, {:ok, %{}}, fn profile, {:ok, acc} ->
      case AppConfigure.get_override_by_key(scope, profile_key(profile)) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, profile, entry(value, layer_source(scope), profile))}}

        :error ->
          {:cont, {:ok, acc}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp layer_source({:system, _uid}), do: :system
  defp layer_source(scope), do: scope

  defp hosted_configuration(agent_overrides, :agent) do
    with {:ok, tenant} <- read_hosted_layer(:tenant),
         {:ok, global} <- read_hosted_layer(:global) do
      inherited = Map.merge(global, tenant)
      direct = Map.merge(inherited, value_entries(agent_overrides, :agent))

      {:ok,
       %{
         overrides: agent_overrides,
         inherited: complete_hosted(inherited),
         effective: complete_hosted(direct)
       }}
    end
  end

  defp hosted_configuration(_agent_overrides, scope) do
    with {:ok, current} <- read_hosted_layer(scope),
         {:ok, inherited} <- inherited_hosted_layer(scope) do
      {:ok,
       %{
         overrides: entry_values(current),
         inherited: complete_hosted(inherited),
         effective: complete_hosted(Map.merge(inherited, current))
       }}
    end
  end

  defp inherited_hosted_layer(:tenant), do: read_hosted_layer(:global)
  defp inherited_hosted_layer(:global), do: {:ok, %{}}

  defp read_hosted_layer(scope) do
    Enum.reduce_while(@provider_hosted_capabilities, {:ok, %{}}, fn capability, {:ok, acc} ->
      case AppConfigure.get_override_by_key(scope, provider_hosted_key(capability)) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, capability, entry(value, scope, capability))}}

        :error ->
          {:cont, {:ok, acc}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp value_entries(values, source) do
    Map.new(values, fn {profile, value} -> {profile, entry(value, source, profile)} end)
  end

  defp entry_values(entries) do
    Map.new(entries, fn {profile, %{value: value}} -> {profile, value} end)
  end

  defp complete_inherited(entries, profiles) do
    Map.new(profiles, fn profile ->
      {profile, Map.get(entries, profile, empty_entry(profile))}
    end)
  end

  defp complete_hosted(entries) do
    Map.new(@provider_hosted_capabilities, fn capability ->
      {capability,
       Map.get(
         entries,
         capability,
         entry(provider_hosted_default(capability), :default, capability)
       )}
    end)
  end

  defp effective_entries(direct, profiles) do
    Map.new(profiles, fn profile ->
      resolved_profile = resolved_profile(direct, profile)
      selected = Map.get(direct, resolved_profile, empty_entry(resolved_profile))
      {profile, %{selected | resolved_from_profile: resolved_profile}}
    end)
  end

  defp resolved_profile(direct, "coding") do
    Enum.find(["coding", "heavy", "primary"], "primary", &Map.has_key?(direct, &1))
  end

  defp resolved_profile(direct, "light") do
    if Map.has_key?(direct, "light"), do: "light", else: "primary"
  end

  defp resolved_profile(_direct, profile), do: profile

  defp empty_entry(profile), do: entry(nil, :default, profile)

  defp entry(value, source, resolved_from_profile) do
    %{value: value, source: source, resolved_from_profile: resolved_from_profile}
  end

  defp bare_profiles(entries) do
    Enum.reduce(entries, %{}, fn
      {_profile, %{value: nil}}, acc ->
        acc

      {profile, %{value: value, resolved_from_profile: resolved}}, acc ->
        value =
          if resolved == profile,
            do: value,
            else: Map.put(value, "fallback_profile", resolved)

        Map.put(acc, profile, value)
    end)
  end

  defp bare_provider_hosted(entries) do
    Map.new(entries, fn {capability, %{value: value}} -> {capability, value} end)
  end

  defp put_provider_hosted_defaults(scope, updates) do
    Enum.reduce_while(updates, {:ok, []}, fn {capability, value}, {:ok, acc} ->
      case put_default_value(scope, provider_hosted_key(capability), value) do
        {:ok, stored} -> {:cont, {:ok, [{capability, stored} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_default_value(:global, key, nil),
    do: delete_default(AppConfigure.delete_global_by_key(key))

  defp put_default_value(:tenant, key, nil),
    do: delete_default(AppConfigure.delete_tenant_by_key(key))

  defp put_default_value({:system, uid}, key, nil),
    do: delete_default(AppConfigure.delete_system_by_key(uid, key))

  defp put_default_value({:system, uid}, key, value),
    do: AppConfigure.put_system_by_key(uid, key, value)

  defp put_default_value(:global, key, value), do: AppConfigure.put_global_by_key(key, value)
  defp put_default_value(:tenant, key, value), do: AppConfigure.put_tenant_by_key(key, value)

  defp delete_default(:ok), do: {:ok, nil}
  defp delete_default({:error, _reason} = error), do: error

  def profile_key(profile), do: "ai_gateway.model_profiles.#{profile}"
  def provider_hosted_key(capability), do: "ai_gateway.provider_hosted.#{capability}"

  defp model_profile_schema do
    Schema.new(fn
      %{} = value ->
        with :ok <- only_profile_keys(value),
             :ok <- required_profile_text(value, "provider_id"),
             :ok <- required_profile_text(value, "model"),
             :ok <- optional_profile_object(value, "provider_options"),
             :ok <- optional_profile_context_length(value) do
          {:ok, value}
        end

      _value ->
        {:error, :not_model_config}
    end)
  end

  defp only_profile_keys(value) do
    case Map.keys(value) -- ["provider_id", "model", "provider_options", "context_length"] do
      [] -> :ok
      [key | _rest] -> {:error, {:invalid_field, key}}
    end
  end

  defp required_profile_text(value, key) do
    case Map.get(value, key) do
      text when is_binary(text) and text != "" -> :ok
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_profile_object(value, key) do
    case Map.get(value, key) do
      nil ->
        :ok

      %{} = options ->
        if Schema.json_value?(options), do: :ok, else: {:error, {:invalid_field, key}}

      _value ->
        {:error, {:invalid_field, key}}
    end
  end

  defp optional_profile_context_length(value) do
    case Map.get(value, "context_length") do
      nil -> :ok
      length when is_integer(length) and length > 0 -> :ok
      _value -> {:error, {:invalid_field, "context_length"}}
    end
  end

  defp normalize_default_profile_attrs(_profile, nil), do: {:ok, nil}

  defp normalize_default_profile_attrs(profile, attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with :ok <- fixed_profile_description(attrs),
         {:ok, normalized} <-
           normalize_aigateway_profile(profile, attrs, capability_for_default(profile)) do
      {:ok, normalized}
    end
  end

  defp normalize_default_profile_attrs(_profile, _attrs), do: {:error, :invalid_model_profile}

  defp fixed_profile_description(attrs) do
    if Map.has_key?(attrs, "description"),
      do: {:error, :fixed_model_profile_description_not_allowed},
      else: :ok
  end

  defp capability_for_default("rerank"), do: "rerank"
  defp capability_for_default(profile), do: capability_for_profile(profile)

  defp normalize_pod_profile(profile) when is_binary(profile) do
    profile = profile |> String.trim() |> String.downcase()
    if profile in @pod_profiles, do: {:ok, profile}, else: {:error, :invalid_model_profile}
  end

  defp normalize_pod_profile(_profile), do: {:error, :invalid_model_profile}

  defp fetch_agent(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      case Principals.get_agent(agent_uid) do
        {:ok, %{agent: %Agent{} = agent}} -> {:ok, agent}
        {:error, :not_found} -> {:error, :agent_not_found}
        {:error, _error} = error -> error
      end
    end
  end

  defp lock_agent(agent_uid), do: Principals.lock_agent_in_tx(agent_uid)

  defp update_agent_options(agent, options) do
    agent
    |> Principals.options_agent(%{options: options})
    |> Ankole.Errors.reason()
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

  defp profile_result(%{value: nil}, _profile), do: {:error, :model_profile_not_configured}

  defp profile_result(%{value: %{} = attrs} = selected, profile) do
    attrs = Map.put(attrs, "profile", profile)
    resolved = selected.resolved_from_profile

    {:ok, if(resolved == profile, do: attrs, else: Map.put(attrs, "fallback_profile", resolved))}
  end

  defp profile_result(_value, _profile), do: {:error, :invalid_model_profile}

  @doc """
  Canonicalizes a model profile name before authorization and execution.
  """
  @spec canonicalize_profile(String.t()) :: String.t()
  def canonicalize_profile(profile) when is_binary(profile) do
    trimmed = String.trim(profile)
    fixed_profile = String.downcase(trimmed)

    if fixed_profile in @profiles, do: fixed_profile, else: trimmed
  end

  defp normalize_profile(profile) when is_binary(profile) do
    profile = canonicalize_profile(profile)

    if profile in @profiles or custom_profile_name?(profile) do
      {:ok, profile}
    else
      {:error, :invalid_model_profile}
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

  defp normalize_profile_attrs(_profile, nil), do: {:ok, nil}
  defp normalize_profile_attrs(_profile, %{} = attrs) when map_size(attrs) == 0, do: {:ok, nil}

  defp normalize_profile_attrs(profile, attrs) when is_map(attrs) do
    attrs = Attrs.normalize_external_attrs(attrs)

    with {:ok, description} <- normalize_profile_description(profile, attrs),
         {:ok, normalized_profile} <-
           normalize_aigateway_profile(profile, attrs, capability_for_profile(profile)) do
      {:ok, maybe_put_description(normalized_profile, description)}
    end
  end

  defp normalize_profile_attrs(_profile, _attrs), do: {:error, :invalid_model_profile}

  defp normalize_aigateway_profile(profile, attrs, capability) do
    with {:ok, provider_id} <-
           Attrs.required_text(Map.get(attrs, "provider_id"), {:missing, "provider_id"}),
         {:ok, model} <- Attrs.required_text(Map.get(attrs, "model"), {:missing, "model"}),
         {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id),
         {:ok, provider_kind} <- Providers.fetch(provider.provider_kind),
         :ok <- validate_profile_provider(capability, provider_kind),
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

  defp validate_profile_provider(
         capability,
         %Ankole.AIGateway.ProviderDefinition{} = provider_kind
       ) do
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
    case Ankole.Attrs.integer_value(value) do
      integer when is_integer(integer) and integer > 0 -> {:ok, integer}
      _value -> {:error, :invalid_context_length}
    end
  end

  defp normalize_context_length(_value), do: {:error, :invalid_context_length}

  defp maybe_put_context_length(profile, nil), do: profile

  defp maybe_put_context_length(profile, context_length),
    do: Map.put(profile, "context_length", context_length)

  defp normalize_profile_description(profile, attrs) do
    if custom_profile_name?(profile) do
      with {:ok, description} <-
             Attrs.required_text(Map.get(attrs, "description"), {:missing, "description"}),
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

  defp put_profile_options(options, profile, nil) do
    {:ok, replace_models(options, &Map.delete(&1, profile))}
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

  defp capability_for_profile("web_search"), do: "web_search"
  defp capability_for_profile("web_fetch"), do: "web_fetch"
  defp capability_for_profile("image_generate"), do: "image_generate"
  defp capability_for_profile(_profile), do: "llm"

  defp normalize_uid!(uid) do
    {:ok, uid} = Principals.normalize_uid(uid)
    uid
  end
end
