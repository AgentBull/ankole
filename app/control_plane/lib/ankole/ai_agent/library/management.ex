defmodule Ankole.AIAgent.Library.Management do
  @moduledoc "Human management checks for Skill packages and Agent contracts."
  alias Ankole.{AuthZ, Principals}

  def member(%AuthZ.Actor{principal: %{type: :human, membership: :member, status: :active}}),
    do: :ok

  def member(_actor), do: {:error, :forbidden}

  def authorize(actor, resource, action \\ "update") do
    with :ok <- member(actor) do
      if actor.authn["surface"] == "console_rest" do
        with {:ok, tenant} <- Ankole.Tenants.privileged_id() do
          Ankole.Repo.with_tenant(tenant, fn ->
            AuthZ.authorize(actor, console_resource(resource), action)
          end)
        end
      else
        AuthZ.authorize(actor, resource, action)
      end
    end
  end

  def skill(actor, %{agent_uid: uid}, action) when is_binary(uid),
    do: agent(actor, uid, action)

  def skill(actor, %{source_kind: :custom}, action),
    do: authorize(actor, "tenant_console:custom_skills", action)

  def skill(actor, _skill, action), do: authorize(actor, "tenant_console:skills", action)

  def agent(actor, nil, "read"), do: member(actor)
  def agent(actor, nil, action), do: authorize(actor, "tenant_console:agent_contracts", action)

  def agent(actor, uid, action) do
    with :ok <- member(actor), {:ok, %{agent: agent}} <- Principals.get_agent(uid) do
      case agent do
        %{type: :personal_assistant, owner_principal_uid: owner} ->
          if owner?(actor, owner), do: :ok, else: {:error, :forbidden}

        %{type: :ai_colleague} when action == "read" ->
          :ok

        %{type: :ai_colleague} ->
          authorize(actor, "tenant_console:agent:#{uid}", action)
      end
    end
  end

  def binding(actor, uid) do
    with :ok <- member(actor), {:ok, %{agent: agent}} <- Principals.get_agent(uid) do
      case agent do
        %{type: :personal_assistant, owner_principal_uid: owner} ->
          if owner?(actor, owner), do: :ok, else: {:error, :forbidden}

        %{type: :ai_colleague} ->
          case authorize(actor, "tenant_console:skill_bindings") do
            :ok -> :ok
            _ -> authorize(actor, "tenant_console:agent_skill_binding:#{uid}")
          end
      end
    end
  end

  defp owner?(actor, uid),
    do: actor.principal.uid == uid and actor.principal.tenant_id == Ankole.Repo.tenant_id!()

  defp console_resource("tenant_console:agent:" <> uid), do: "site_console:agent:#{uid}:library"

  defp console_resource("tenant_console:agent_skill_binding:" <> uid),
    do: "site_console:agent:#{uid}:library"

  defp console_resource(_resource), do: "site_console:agent_library"

  def seed_grants_in_tx do
    with {:ok, group} <- Ankole.AuthZ.Root.ensure_all_humans_group(),
         {:ok, _} <-
           Ankole.AuthZ.Grants.upsert_permission_grants(
             Enum.map(
               ["update", "delete"],
               &%{
                 group_id: group.id,
                 resource_pattern: "tenant_console:custom_skills",
                 action: &1
               }
             )
           ),
         do: :ok
  end

  def committed(result) do
    Phoenix.PubSub.broadcast(
      Ankole.PubSub,
      "drive-vfs-access:" <> Ankole.Repo.tenant_id!(),
      :vfs_access_changed
    )

    result
  end
end
