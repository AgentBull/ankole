defmodule Ankole.SignalsGateway.ActorRuntime.TurnPolicy do
  @moduledoc false

  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.ProviderDefinition
  alias Ankole.AIGateway.Providers
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig

  @spec build_turn_start_spec(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def build_turn_start_spec(actor_key, opts \\ []) when is_map(actor_key) do
    with {:ok, model_ref} <-
           turn_model_ref(actor_key.agent_uid, Keyword.get(opts, :profile, "primary")),
         {:ok, runtime_policy} <-
           AgentConfig.runtime_policy(actor_key.agent_uid,
             max_completion_tokens: model_ref["max_completion_tokens"]
           ) do
      {:ok,
       %{
         model_ref: model_ref,
         request_context:
           request_context(
             actor_key,
             model_ref,
             runtime_policy,
             Keyword.get(opts, :request_context, %{})
           )
       }
       |> maybe_put(:hosted_tools, hosted_tools(actor_key.agent_uid, model_ref))}
    end
  end

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
    case ModelProfiles.resolve_runtime_profile(agent_uid, profile) do
      {:ok, runtime_profile} ->
        model_ref = model_ref_from_runtime_profile(runtime_profile)
        {:ok, maybe_put_vision_fallback_model_ref(model_ref, agent_uid)}

      {:error, reason} ->
        {:error, {:model_profile_unavailable, profile, reason}}
    end
  end

  defp hosted_tools(agent_uid, model_ref) do
    if Providers.supports_native_image_generation?(model_ref) do
      [%{"type" => "image_generation"}]
    else
      case ModelProfiles.resolve_runtime_profile(agent_uid, "image_generate") do
        {:ok, _runtime_profile} -> [%{"type" => "image_generation"}]
        {:error, _reason} -> nil
      end
    end
  end

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
    |> maybe_put("context_length", Map.get(runtime_profile, "context_length"))
    |> maybe_put(
      "max_completion_tokens",
      max_completion_tokens_for_runtime_profile(runtime_profile)
    )
  end

  defp maybe_put_vision_fallback_model_ref(model_ref, agent_uid) do
    if "image" in Map.get(model_ref, "input_modalities", []) do
      model_ref
    else
      case ModelProfiles.resolve_runtime_profile(agent_uid, "vision_fallback") do
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp supports_parallel_tool_calls?(%{"provider_kind" => provider_kind}) do
    with {:ok, provider} <- Providers.fetch(provider_kind),
         {:ok, capability} <- ProviderDefinition.capability(provider, :language_model) do
      capability.supports_parallel_tool_calls?
    else
      _error -> false
    end
  end

  defp supports_parallel_tool_calls?(_runtime_profile), do: false
end
