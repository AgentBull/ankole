defmodule Ankole.SignalsGateway.ActorRuntime.TurnPolicy do
  @moduledoc false

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Providers
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig

  @spec build_turn_start_spec(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_turn_start_spec(actor_key, opts \\ []) when is_map(actor_key) do
    with {:ok, turn_basis} <- turn_basis(actor_key.agent_uid, opts),
         {:ok, custom_model_profiles} <-
           ModelProfiles.list_custom_model_profiles(actor_key.agent_uid) do
      model_ref = turn_basis.model_ref

      {:ok,
       %{
         model_ref: model_ref,
         request_context:
           request_context(
             actor_key,
             model_ref,
             turn_basis.runtime_policy,
             Keyword.get(opts, :request_context, %{})
             |> Map.put("custom_model_profiles", custom_model_profiles)
           )
       }
       |> maybe_put(:hosted_tools, turn_basis.hosted_tools)}
    end
  end

  defp turn_basis(agent_uid, opts) do
    case Keyword.fetch(opts, :turn_start_overrides) do
      {:ok, {:ok, overrides}} -> frozen_turn_basis(overrides)
      {:ok, {:error, _reason} = error} -> error
      {:ok, other} -> {:error, {:invalid_turn_start_overrides, other}}
      :error -> resolved_turn_basis(agent_uid, opts)
    end
  end

  defp resolved_turn_basis(agent_uid, opts) do
    with {:ok, model_ref} <-
           turn_model_ref(agent_uid, Keyword.get(opts, :profile, "primary")),
         {:ok, runtime_policy} <-
           AgentConfig.runtime_policy(agent_uid,
             max_completion_tokens: model_ref["max_completion_tokens"]
           ) do
      {:ok,
       %{
         model_ref: model_ref,
         runtime_policy: runtime_policy,
         hosted_tools: hosted_tools(agent_uid, model_ref)
       }}
    end
  end

  defp frozen_turn_basis(
         %{
           model_ref: %{} = model_ref,
           request_context: %{"ai_agent" => %{} = runtime_policy}
         } = overrides
       ) do
    {:ok,
     %{
       model_ref: model_ref,
       runtime_policy: runtime_policy,
       hosted_tools: Map.get(overrides, :hosted_tools)
     }}
  end

  defp frozen_turn_basis(_overrides), do: {:error, :invalid_turn_start_overrides}

  defp request_context(actor_key, model_ref, runtime_policy, extra_context)
       when is_map(extra_context) do
    %{
      "actor_key" => %{
        "agent_uid" => actor_key.agent_uid,
        "session_id" => actor_key.session_id
      },
      "model_ref" => model_ref
    }
    |> Map.merge(extra_context)
    |> Map.put("ai_agent", runtime_policy)
  end

  defp request_context(actor_key, model_ref, runtime_policy, _extra_context) do
    request_context(actor_key, model_ref, runtime_policy, %{})
  end

  defp turn_model_ref(agent_uid, profile) do
    case ModelProfiles.resolve_runtime_model_ref(agent_uid, profile) do
      {:ok, model_ref} -> {:ok, model_ref}
      {:error, reason} -> {:error, {:model_profile_unavailable, profile, reason}}
    end
  end

  defp hosted_tools(agent_uid, model_ref) do
    case image_generation_hosted_tools(agent_uid, model_ref) ++ web_search_hosted_tools(model_ref) do
      [] -> nil
      tools -> tools
    end
  end

  defp image_generation_hosted_tools(agent_uid, model_ref) do
    if Providers.supports_native_image_generation?(model_ref) do
      [%{"type" => "image_generation"}]
    else
      case ModelProfiles.resolve_runtime_profile(agent_uid, "image_generate") do
        {:ok, _runtime_profile} -> [%{"type" => "image_generation"}]
        {:error, _reason} -> []
      end
    end
  end

  defp web_search_hosted_tools(model_ref) do
    if ProviderConfigs.supports_hosted_web_search?(model_ref) do
      [%{"type" => "web_search"}]
    else
      []
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
