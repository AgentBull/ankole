defmodule BullX.Setup.AIAgents do
  @moduledoc false

  import Ecto.Query

  alias BullX.AIAgent.Profile
  alias BullX.AuthZ
  alias BullX.AuthZ.{PermissionGrant, PrincipalGroup}
  alias BullX.LLM.Catalog
  alias BullX.Principals
  alias BullX.Repo

  @setup_role "initial_ai_agent"
  @default_mission "Help this BullX Installation handle addressed messages."

  @spec status(map()) :: map()
  def status(session \\ %{}) do
    agents = Principals.list_active_agents()
    selected = select_initial_agent(agents, session[:agent_principal_id])

    %{
      complete?: selected_complete?(selected),
      agents: Enum.map(agents, &public_agent/1),
      selected_agent: public_agent(selected),
      groups: group_projection(),
      acl_preview: acl_preview(selected)
    }
  end

  @spec save(map(), map()) :: {:ok, map()} | {:error, map()}
  def save(attrs, session \\ %{})

  def save(attrs, session) when is_map(attrs) do
    with :ok <- AuthZ.reconcile_bootstrap_admin_membership(),
         {:ok, groups} <- ensure_groups(),
         {:ok, profile} <- profile_from_attrs(attrs),
         {:ok, _resolved} <-
           Catalog.resolve_model_spec(get_in(profile, ["ai_agent", "main_model"])),
         {:ok, agent} <- create_or_update_agent(attrs, profile, session),
         :ok <- ensure_acl(agent.principal.id, groups, attrs) do
      {:ok,
       %{
         agent: public_agent(agent),
         acl_preview: acl_preview(agent),
         ordinary_group_id: groups.all_humans.id,
         privileged_group_id: groups.admin.id
       }}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  def save(_attrs, _session), do: {:error, %{message: "invalid AIAgent payload"}}

  defp select_initial_agent(agents, selected_id) do
    agents
    |> select_session_agent(selected_id)
    |> select_setup_marked_agent(agents)
    |> select_sole_agent(agents)
  end

  defp select_session_agent(agents, selected_id) when is_binary(selected_id) do
    Enum.find(agents, &(&1.principal.id == selected_id))
  end

  defp select_session_agent(_agents, _selected_id), do: nil

  defp select_setup_marked_agent(nil, agents) do
    Enum.find(agents, &(get_in(&1.agent.profile, ["setup", "role"]) == @setup_role))
  end

  defp select_setup_marked_agent(agent, _agents), do: agent

  defp select_sole_agent(nil, [agent]), do: agent
  defp select_sole_agent(agent, _agents), do: agent

  defp selected_complete?(nil), do: false

  defp selected_complete?(agent) do
    with {:ok, _profile} <- Profile.cast(agent.agent.profile),
         {:ok, _resolved} <-
           Catalog.resolve_model_spec(get_in(agent.agent.profile, ["ai_agent", "main_model"])),
         true <- required_acl_grants?(agent.principal.id) do
      true
    else
      _other -> false
    end
  end

  defp profile_from_attrs(attrs) do
    profile =
      case map_value(attrs, "profile") do
        %{} = full when is_map_key(full, "ai_agent") ->
          full

        %{} = ai_agent ->
          %{"ai_agent" => ai_agent}

        _other ->
          default_profile(attrs)
      end
      |> put_in(["setup"], %{"role" => @setup_role})

    case Profile.cast(profile) do
      {:ok, _profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_profile(attrs) do
    %{
      "ai_agent" => %{
        "main_model" => string_value(attrs, "main_model", ""),
        "mission" => string_value(attrs, "mission", @default_mission),
        "soul" => string_value(attrs, "soul", ""),
        "instructions" => string_value(attrs, "instructions", ""),
        "conversation_isolation_mode" => "scene",
        "unmentioned_group_messages" => "may_intervene",
        "acl" => %{"elevation_strategy" => "deny"}
      }
    }
  end

  defp create_or_update_agent(attrs, profile, session) do
    selected_id = string_value(attrs, "agent_principal_id", session[:agent_principal_id])

    principal_attrs = %{
      uid: string_value(attrs, "uid", generated_uid()),
      display_name: string_value(attrs, "display_name", "BullX Agent"),
      bio: string_value(attrs, "bio", nil),
      avatar_url: string_value(attrs, "avatar_url", nil),
      status: :active
    }

    agent_attrs = %{profile: profile, created_by_principal_id: nil}

    case selected_id do
      id when is_binary(id) and id != "" ->
        with {:ok, result} <-
               Principals.update_agent(id, %{principal: principal_attrs, agent: agent_attrs}) do
          {:ok, result}
        end

      _other ->
        Principals.create_agent(%{principal: principal_attrs, agent: agent_attrs})
    end
  end

  defp ensure_groups do
    with {:ok, all_humans, _} <- AuthZ.ensure_built_in_all_humans_group(),
         {:ok, admin, _} <- AuthZ.ensure_built_in_admin_group() do
      {:ok, %{all_humans: all_humans, admin: admin}}
    end
  end

  defp ensure_acl(agent_principal_id, groups, attrs) do
    ordinary_group_id = string_value(attrs, "ordinary_group_id", groups.all_humans.id)
    privileged_group_id = string_value(attrs, "privileged_group_id", groups.admin.id)

    grants =
      [
        group_grant(ordinary_group_id, agent_principal_id, "invoke"),
        group_grant(privileged_group_id, agent_principal_id, "invoke"),
        group_grant(privileged_group_id, agent_principal_id, "invoke_privileged"),
        principal_grant(agent_principal_id, agent_principal_id, "invoke")
      ]
      |> Enum.uniq_by(&{&1[:principal_id], &1[:group_id], &1[:resource_pattern], &1[:action]})

    Enum.reduce_while(grants, :ok, fn grant, :ok ->
      case AuthZ.upsert_permission_grant(grant) do
        {:ok, _grant} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp group_grant(group_id, agent_principal_id, action) do
    %{
      group_id: group_id,
      resource_pattern: "ai_agent:#{agent_principal_id}",
      action: action,
      condition: "true",
      description: "Setup initial AIAgent #{action} grant.",
      metadata: %{"created_by" => "setup", "setup_role" => "initial_ai_agent_acl"}
    }
  end

  defp principal_grant(principal_id, agent_principal_id, action) do
    %{
      principal_id: principal_id,
      resource_pattern: "ai_agent:#{agent_principal_id}",
      action: action,
      condition: "true",
      description: "Setup initial AIAgent self grant.",
      metadata: %{"created_by" => "setup", "setup_role" => "initial_ai_agent_acl"}
    }
  end

  defp required_acl_grants?(agent_principal_id) do
    resource = "ai_agent:#{agent_principal_id}"

    with %PrincipalGroup{id: all_humans_id} <-
           Repo.get_by(PrincipalGroup, name: "all_humans", built_in: true),
         %PrincipalGroup{id: admin_id} <-
           Repo.get_by(PrincipalGroup, name: "admin", built_in: true) do
      group_grant_exists?(all_humans_id, resource, "invoke") and
        group_grant_exists?(admin_id, resource, "invoke") and
        group_grant_exists?(admin_id, resource, "invoke_privileged") and
        principal_grant_exists?(agent_principal_id, resource, "invoke")
    else
      _other -> false
    end
  end

  defp group_grant_exists?(group_id, resource, action) do
    Repo.exists?(
      from grant in PermissionGrant,
        where:
          grant.group_id == ^group_id and grant.resource_pattern == ^resource and
            grant.action == ^action and grant.condition == "true",
        select: 1
    )
  end

  defp principal_grant_exists?(principal_id, resource, action) do
    Repo.exists?(
      from grant in PermissionGrant,
        where:
          grant.principal_id == ^principal_id and grant.resource_pattern == ^resource and
            grant.action == ^action and grant.condition == "true",
        select: 1
    )
  end

  defp public_agent(nil), do: nil

  defp public_agent(%{principal: principal, agent: agent}) do
    %{
      principal_id: principal.id,
      uid: principal.uid,
      display_name: principal.display_name,
      bio: principal.bio,
      avatar_url: principal.avatar_url,
      profile: agent.profile
    }
  end

  defp group_projection do
    _ = AuthZ.reconcile_bootstrap_admin_membership()

    PrincipalGroup
    |> where([group], group.name in ["admin", "all_humans"])
    |> order_by([group], asc: group.name)
    |> Repo.all()
    |> Enum.map(&Map.take(&1, [:id, :name, :kind, :description, :built_in]))
  end

  defp acl_preview(nil), do: []

  defp acl_preview(%{principal: principal}) do
    [
      %{
        subject: "group:all_humans",
        resource: "ai_agent:#{principal.id}",
        action: "invoke",
        condition: "true"
      },
      %{
        subject: "group:admin",
        resource: "ai_agent:#{principal.id}",
        action: "invoke",
        condition: "true"
      },
      %{
        subject: "group:admin",
        resource: "ai_agent:#{principal.id}",
        action: "invoke_privileged",
        condition: "true"
      },
      %{
        subject: "principal:#{principal.id}",
        resource: "ai_agent:#{principal.id}",
        action: "invoke",
        condition: "true"
      }
    ]
  end

  defp map_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))

  defp string_value(attrs, key, default), do: attrs |> map_value(key) |> trim_string(default)

  defp trim_string(value, default) when is_binary(value),
    do: if(String.trim(value) == "", do: default, else: String.trim(value))

  defp trim_string(nil, default), do: default
  defp trim_string(value, _default), do: value

  defp generated_uid do
    "agent-" <> String.slice(BullX.Ext.gen_base36_uuid(), 0, 10)
  end

  defp normalize_error({:invalid_profile, errors}),
    do: %{field: "profile", message: "invalid profile", errors: errors}

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{message: "validation failed", errors: changeset_errors(changeset)}

  defp normalize_error(reason), do: %{message: inspect(reason)}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
