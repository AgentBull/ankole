defmodule BullX.Setup.AIAgents do
  @moduledoc false

  import Ecto.Query

  alias BullX.AIAgent.Profile
  alias BullX.AuthZ
  alias BullX.AuthZ.{PermissionGrant, PrincipalGroup}
  alias BullX.LLM.{Catalog, ModelConfig}
  alias BullX.Principals
  alias BullX.Repo
  alias BullXHarness.DefaultTemplate

  @setup_role "initial_ai_agent"

  @spec default_soul() :: String.t()
  def default_soul, do: DefaultTemplate.soul()

  @spec status(map()) :: map()
  def status(session \\ %{}) do
    agents = Principals.list_active_agents()
    selected = select_initial_agent(agents, session[:agent_uid])

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
    with {:ok, profile} <- profile_from_attrs(attrs),
         :ok <- resolve_profile_models(profile),
         {:ok, agent} <- create_or_update_agent(attrs, profile, session),
         :ok <- ensure_agent_acl(agent.principal.uid) do
      {:ok,
       %{
         agent: public_agent(agent),
         acl_preview: acl_preview(agent)
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
    Enum.find(agents, &(&1.principal.uid == selected_id))
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
    with {:ok, profile} <- Profile.cast(agent.agent.profile),
         {:ok, _resolved} <- Catalog.resolve_model_config(profile.main_llm),
         true <- required_agent_acl_grant?(agent.principal.uid) do
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
    main_llm = llm_config(attrs, "main_llm", :medium)
    compression_llm = llm_config(attrs, "compression_llm", :low) || with_effort(main_llm, :low)
    heavy_llm = llm_config(attrs, "heavy_llm", :high) || with_effort(main_llm, :high)

    %{
      "ai_agent" => %{
        "main_llm" => main_llm,
        "compression_llm" => compression_llm,
        "heavy_llm" => heavy_llm,
        "mission" => string_value(attrs, "mission", nil),
        "soul" => soul_value(attrs),
        "instructions" => string_value(attrs, "instructions", ""),
        "conversation_isolation_mode" => "scene",
        "unmentioned_group_messages" => "may_intervene",
        "acl" => %{"elevation_strategy" => "deny"}
      }
    }
  end

  defp llm_config(attrs, key, default_reasoning_effort) do
    case map_value(attrs, key) do
      %{} = config ->
        Map.put_new(config, "reasoning_effort", Atom.to_string(default_reasoning_effort))

      _missing ->
        nil
    end
  end

  defp with_effort(%{} = config, effort),
    do: Map.put(config, "reasoning_effort", Atom.to_string(effort))

  defp with_effort(nil, _effort), do: nil

  defp resolve_profile_models(profile) do
    with {:ok, cast_profile} <- Profile.cast(profile) do
      [cast_profile.main_llm, cast_profile.compression_llm, cast_profile.heavy_llm]
      |> Enum.uniq_by(&{&1.provider_id, &1.model})
      |> Enum.reduce_while(:ok, fn model, :ok ->
        case Catalog.resolve_model_config(model) do
          {:ok, _resolved} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:unresolved_model, model, reason}}}
        end
      end)
    end
  end

  defp create_or_update_agent(attrs, profile, session) do
    selected_id = string_value(attrs, "agent_uid", session[:agent_uid])

    principal_attrs = %{
      uid: string_value(attrs, "uid", generated_uid()),
      display_name: string_value(attrs, "display_name", "BullX Agent"),
      avatar_url: string_value(attrs, "avatar_url", nil),
      status: :active
    }

    agent_attrs = %{type: :ai_agent, profile: profile, created_by_principal_uid: nil}

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

  defp ensure_agent_acl(agent_uid) do
    with {:ok, all_humans, _status} <- AuthZ.ensure_built_in_all_humans_group(),
         :ok <-
           upsert_agent_acl_grant(principal_grant(agent_uid, agent_uid, "invoke")),
         :ok <- upsert_agent_acl_grant(group_grant(all_humans.id, agent_uid, "invoke")) do
      :ok
    end
  end

  defp upsert_agent_acl_grant(attrs) do
    case AuthZ.upsert_permission_grant(attrs) do
      {:ok, _grant} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp principal_grant(principal_uid, agent_uid, action) do
    %{
      principal_uid: principal_uid,
      resource_pattern: "ai_agent:#{agent_uid}",
      action: action,
      condition: "true",
      description: "Setup initial AIAgent self grant.",
      metadata: %{"created_by" => "setup", "setup_role" => "initial_ai_agent_acl"}
    }
  end

  defp group_grant(group_id, agent_uid, action) do
    %{
      group_id: group_id,
      resource_pattern: "ai_agent:#{agent_uid}",
      action: action,
      condition: "true",
      description: "Setup initial AIAgent all humans grant.",
      metadata: %{
        "created_by" => "setup",
        "setup_role" => "initial_ai_agent_acl",
        "subject" => "all_humans"
      }
    }
  end

  defp required_agent_acl_grant?(agent_uid) do
    resource = "ai_agent:#{agent_uid}"

    principal_grant_exists?(agent_uid, resource, "invoke") and
      group_grant_exists?("all_humans", resource, "invoke")
  end

  defp principal_grant_exists?(principal_uid, resource, action) do
    Repo.exists?(
      from grant in PermissionGrant,
        where:
          grant.principal_uid == ^principal_uid and grant.resource_pattern == ^resource and
            grant.action == ^action and grant.condition == "true",
        select: 1
    )
  end

  defp group_grant_exists?(group_name, resource, action) do
    Repo.exists?(
      from grant in PermissionGrant,
        join: group in assoc(grant, :group),
        where:
          group.name == ^group_name and grant.resource_pattern == ^resource and
            grant.action == ^action and grant.condition == "true",
        select: 1
    )
  end

  defp public_agent(nil), do: nil

  defp public_agent(%{principal: principal, agent: agent}) do
    %{
      principal_uid: principal.uid,
      uid: principal.uid,
      display_name: principal.display_name,
      avatar_url: principal.avatar_url,
      type: Atom.to_string(agent.type),
      profile: agent.profile
    }
  end

  defp group_projection do
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
        resource: "ai_agent:#{principal.uid}",
        action: "invoke",
        condition: "true"
      },
      %{
        subject: "principal:#{principal.uid}",
        resource: "ai_agent:#{principal.uid}",
        action: "invoke",
        condition: "true"
      }
    ]
  end

  defp map_value(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(attrs, key)
  end

  defp string_value(attrs, key, default), do: attrs |> map_value(key) |> trim_string(default)

  defp soul_value(attrs) do
    case map_value(attrs, "soul") do
      nil -> default_soul()
      value when is_binary(value) -> String.trim(value)
      value -> value
    end
  end

  defp trim_string(value, default) when is_binary(value),
    do: if(String.trim(value) == "", do: default, else: String.trim(value))

  defp trim_string(nil, default), do: default
  defp trim_string(value, _default), do: value

  defp generated_uid do
    "agent-" <> String.slice(BullX.Ext.gen_base36_uuid(), 0, 10)
  end

  defp normalize_error({:invalid_profile, errors}),
    do: %{field: "profile", message: "invalid profile", errors: errors}

  defp normalize_error({:unresolved_model, %ModelConfig{} = config, reason}),
    do: %{
      field: "profile",
      message: "unresolved model #{config.provider_id}:#{config.model}",
      reason: inspect(reason)
    }

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
