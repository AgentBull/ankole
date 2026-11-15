defmodule Ankole.AIGateway.ModelProfiles.Delegation do
  @moduledoc """
  Projects and validates delegation model profiles (`light`, `primary`, `heavy`,
  and Agent custom LLM profiles) from a single subject profile snapshot.
  """

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.Resolver

  @spec list_custom_model_profiles(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_custom_model_profiles(agent_uid) do
    with {:ok, profiles} <- ModelProfiles.get_model_profiles(agent_uid) do
      {:ok, custom_profile_entries(profiles)}
    end
  end

  @spec normalize_delegation_profile(term()) ::
          {:ok, ModelProfiles.profile()} | {:error, :invalid_delegation_model_profile}
  def normalize_delegation_profile(profile) when is_binary(profile) do
    profile = ModelProfiles.canonicalize_profile(profile)

    if profile in ModelProfiles.delegation_tier_profiles() or
         ModelProfiles.custom_profile_name?(profile) do
      {:ok, profile}
    else
      {:error, :invalid_delegation_model_profile}
    end
  end

  def normalize_delegation_profile(_profile), do: {:error, :invalid_delegation_model_profile}

  @spec validate_delegation_profile(String.t(), term()) ::
          {:ok, ModelProfiles.profile()} | {:error, term()}
  def validate_delegation_profile(agent_uid, profile) do
    with {:ok, normalized} <- normalize_delegation_profile(profile),
         {:ok, profiles} <- ModelProfiles.get_model_profiles(agent_uid),
         {:ok, _runtime} <- resolve_bound_profile(agent_uid, profiles, normalized) do
      {:ok, normalized}
    end
  end

  @spec available_delegation_profiles(String.t()) ::
          {:ok, %{built_in_tiers: [ModelProfiles.profile()], custom_profiles: [map()]}}
          | {:error, term()}
  def available_delegation_profiles(agent_uid) do
    with {:ok, profiles} <- ModelProfiles.get_model_profiles(agent_uid) do
      resolved_tiers =
        Enum.flat_map(ModelProfiles.delegation_tier_profiles(), fn tier ->
          case resolve_bound_profile(agent_uid, profiles, tier) do
            {:ok, runtime} -> [{tier, delegation_binding_key(runtime)}]
            {:error, _reason} -> []
          end
        end)

      built_in_tiers =
        if resolved_tiers |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1 do
          Enum.map(resolved_tiers, &elem(&1, 0))
        else
          []
        end

      custom_profiles =
        profiles
        |> custom_profile_entries()
        |> Enum.filter(fn %{"name" => name} ->
          match?({:ok, _}, resolve_bound_profile(agent_uid, profiles, name))
        end)

      {:ok, %{built_in_tiers: built_in_tiers, custom_profiles: custom_profiles}}
    end
  end

  defp custom_profile_entries(profiles) do
    profiles
    |> Enum.flat_map(fn
      {name, %{"description" => description}}
      when is_binary(description) and description != "" ->
        if ModelProfiles.custom_profile_name?(name),
          do: [%{"name" => name, "description" => description}],
          else: []

      {_name, _attrs} ->
        []
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp resolve_bound_profile(agent_uid, profiles, profile_name) do
    case Map.get(profiles, profile_name) do
      %{} = attrs ->
        binding = Map.put(attrs, "profile", profile_name)

        Resolver.resolve_request_model(
          agent_uid,
          "llm",
          %{"model" => profile_name},
          model_binding: binding
        )

      nil ->
        {:error, :model_profile_not_configured}
    end
  end

  defp delegation_binding_key(runtime) do
    {runtime["provider_id"], runtime["model"], runtime["provider_options"] || %{}}
  end
end
