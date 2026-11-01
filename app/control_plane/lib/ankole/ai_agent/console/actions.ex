defmodule Ankole.AIAgent.Console.Actions do
  @moduledoc "Runs Console model and quota actions through their domain owners."
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.Errors.Invalid.NotFound

  @impl true
  def run(input, _opts, _context) do
    input.action.name
    |> action(input.arguments)
    |> Ankole.Errors.wrap(&rejection/1)
  end

  defp action(:model_profiles, args),
    do: ModelProfiles.model_profile_configuration(args.agent_uid)

  defp action(:system_principals, _args),
    do: {:ok, %{system_principals: Ankole.Principals.SystemServices.all()}}

  defp action(:system_model_profiles, args),
    do: ModelProfiles.system_model_profile_configuration(args.uid)

  defp action(:put_system_model_profile, args), do: put_system_profile(args, args.attrs)
  defp action(:delete_system_model_profile, args), do: put_system_profile(args, nil)

  defp action(:defaults_model_profiles, args),
    do: ModelProfiles.defaults_model_profile_configuration(args.defaults_scope)

  defp action(:put_default_model_profile, args), do: put_default_profile(args, args.attrs)
  defp action(:delete_default_model_profile, args), do: put_default_profile(args, nil)

  defp action(:put_default_provider_hosted, args) do
    with {:ok, _capabilities} <-
           ModelProfiles.put_default_provider_hosted_capabilities(
             args.defaults_scope,
             Map.drop(args, [:defaults_scope])
           ),
         {:ok, configuration} <- action(:defaults_model_profiles, args) do
      {:ok, configuration}
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
    with {:ok, _profile} <- ModelProfiles.put_model_profile(args.agent_uid, args.profile, attrs),
         do: ModelProfiles.model_profile_configuration(args.agent_uid)
  end

  defp put_system_profile(args, attrs) do
    with {:ok, _profile} <- ModelProfiles.put_system_model_profile(args.uid, args.profile, attrs),
         do: ModelProfiles.system_model_profile_configuration(args.uid)
  end

  defp provider_hosted(capabilities) do
    %{
      web_search: ModelProfiles.provider_hosted?(capabilities, "web_search"),
      image_generate: ModelProfiles.provider_hosted?(capabilities, "image_generate")
    }
  end

  defp put_default_profile(args, attrs) do
    with {:ok, _profile} <-
           ModelProfiles.put_default_model_profile(args.defaults_scope, args.profile, attrs),
         {:ok, configuration} <- action(:defaults_model_profiles, args) do
      {:ok, configuration}
    end
  end

  def default_read_permissions(args, attrs, resource, action),
    do: default_permissions(args, attrs, resource, action)

  def default_provider_hosted_permissions(args, attrs, resource, action),
    do: default_permissions(args, attrs, resource, action)

  def default_permissions(args, _attrs, resource, action) do
    if args["defaults_scope"] in [:global, "global"] do
      [
        {resource, action}
        | Enum.map(
            default_permission_keys(args),
            &{"site_console:app_configuration:#{&1}", action}
          )
      ]
    else
      [{resource, action}]
    end
  end

  defp default_permission_keys(%{"profile" => profile}),
    do: [ModelProfiles.profile_key(profile)]

  defp default_permission_keys(args) do
    hosted =
      ModelProfiles.provider_hosted_capabilities()
      |> Enum.filter(&Map.has_key?(args, &1))
      |> Enum.map(&ModelProfiles.provider_hosted_key/1)

    if hosted == [] and args["action"] != "put_default_provider_hosted" do
      Enum.map(ModelProfiles.pod_profiles(), &ModelProfiles.profile_key/1) ++
        Enum.map(
          ModelProfiles.provider_hosted_capabilities(),
          &ModelProfiles.provider_hosted_key/1
        )
    else
      hosted
    end
  end

  defp rejection(reason)
       when reason in [:not_found, :not_agent, :agent_not_found, :principal_not_found],
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

  defp rejection(:unknown_system_principal), do: {"the system Principal is not registered", []}

  defp rejection(:system_principal_missing),
    do: NotFound.exception(resource: Ankole.Principals.Principal)

  defp rejection(:fixed_model_profile_description_not_allowed),
    do: {"a built-in model profile has no custom description", []}

  defp rejection(_reason), do: {"model configuration is invalid", []}
end
