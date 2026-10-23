defmodule Ankole.AIAgent.Console.Actions do
  @moduledoc "Runs Console model and quota actions through their domain owners."
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIAgent.{ModelProfiles, TokenQuota}
  alias Ankole.Errors.Invalid.NotFound

  @impl true
  def run(input, _opts, _context) do
    input.action.name
    |> action(input.arguments)
    |> Ankole.Errors.wrap(&rejection/1)
  end

  defp action(:model_profiles, args) do
    with {:ok, profiles} <- ModelProfiles.get_model_profiles(args.agent_uid),
         {:ok, capabilities} <- ModelProfiles.provider_hosted_capabilities(args.agent_uid) do
      {:ok, %{model_profiles: profiles, provider_hosted: provider_hosted(capabilities)}}
    end
  end

  defp action(:put_model_profile, args), do: put_profile(args, args.attrs)
  defp action(:delete_model_profile, args), do: put_profile(args, nil)

  defp action(:put_provider_hosted, args) do
    with {:ok, capabilities} <-
           ModelProfiles.put_provider_hosted_capabilities(
             args.agent_uid,
             Map.drop(args, [:agent_uid])
           ) do
      {:ok, %{provider_hosted: provider_hosted(capabilities)}}
    end
  end

  defp action(:token_quota, args), do: TokenQuota.status(args.agent_uid)

  defp action(:put_token_quota, args) do
    with {:ok, _quota} <- TokenQuota.put(args.agent_uid, Map.drop(args, [:agent_uid])),
         do: TokenQuota.status(args.agent_uid)
  end

  defp action(:delete_token_quota, args) do
    with {:ok, nil} <- TokenQuota.delete(args.agent_uid), do: TokenQuota.status(args.agent_uid)
  end

  defp action(:reset_token_quota, args) do
    with {:ok, _quota} <- TokenQuota.reset(args.agent_uid), do: TokenQuota.status(args.agent_uid)
  end

  defp put_profile(args, attrs) do
    with {:ok, %{profile: profile}} <-
           ModelProfiles.put_model_profile(args.agent_uid, args.profile, attrs) do
      {:ok,
       %{
         model_profile:
           Map.merge(profile || %{}, %{
             "profile" => args.profile,
             "configured" => not is_nil(profile)
           })
       }}
    end
  end

  defp provider_hosted(capabilities) do
    %{
      web_search: ModelProfiles.provider_hosted?(capabilities, "web_search"),
      image_generate: ModelProfiles.provider_hosted?(capabilities, "image_generate")
    }
  end

  defp rejection(reason) when reason in [:not_found, :not_agent, :agent_not_found],
    do: NotFound.exception(resource: Ankole.Principals.Agent)

  defp rejection(:image_model_unavailable),
    do: {"selected image model has no usable image-generation endpoint", []}

  defp rejection(:image_model_catalog_unavailable),
    do: {"image model availability could not be verified; try again later", []}

  defp rejection(:invalid_period_days), do: {"period_days must be an integer of at least 1", []}

  defp rejection(:invalid_period_start_at),
    do: {"period_start_at must be an ISO 8601 instant", []}

  defp rejection(:invalid_limit_tokens), do: {"limit_tokens must be an integer of at least 1", []}
  defp rejection(:token_quota_not_configured), do: {"agent has no token quota to reset", []}

  defp rejection({:missing, field}),
    do: {"#{field} is required", [%{path: field, message: "is required"}]}

  defp rejection(:invalid_model_profile), do: {"the model profile name is invalid", []}

  defp rejection(:fixed_model_profile_description_not_allowed),
    do: {"a built-in model profile has no custom description", []}

  defp rejection(_reason), do: {"agent model configuration is invalid", []}
end
