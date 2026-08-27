defmodule Ankole.SignalsGateway.IMGroupMembers do
  @moduledoc """
  Membership writes for `im_group` AuthZ groups shared by IM adapters.

  Entity logic: an Agent joined to a provider room through a binding is a
  member of that room's Principal Group, equal to the human members. Brain
  audience scopes resolve group membership at recall time, so a missing agent
  membership row hides the room's shared knowledge from its own Agent.
  Adapters therefore write human members through this module, which mirrors
  the joined binding Agents in the same transaction.
  """

  import Ecto.Query, warn: false

  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Store
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.SignalsGateway.BindingMembership

  @doc """
  Replaces the members of one `im_group` Group with the given human
  Principals plus the Agents of currently joined bindings.

  A group whose bindings all left mirrors no agents, so a caller that first
  marks every binding left can pass an empty list to clear the group.
  """
  @spec replace_members(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def replace_members(group_id, human_uids) when is_list(human_uids) do
    Repo.transact(fn repo ->
      with {:ok, group} <- lock_group(repo, group_id) do
        uids = Enum.uniq(human_uids ++ joined_agent_uids(repo, group.metadata))
        Store.replace_static_group_members(repo, group.id, :im_group, uids)
      end
    end)
  end

  @doc """
  Reconciles only the Agent membership rows of one `im_group` Group with its
  currently joined bindings. Human membership rows stay unchanged.

  Adapters call this after a binding leaves while other bindings remain, so
  the leaving Agent loses membership at the same time a leaving human would.
  """
  @spec reconcile_agent_members(String.t()) :: {:ok, map()} | {:error, term()}
  def reconcile_agent_members(group_id) do
    Repo.transact(fn repo ->
      with {:ok, group} <- lock_group(repo, group_id) do
        joined = joined_agent_uids(repo, group.metadata)

        current =
          Membership
          |> join(:inner, [membership], principal in Principal,
            on: principal.uid == membership.principal_uid
          )
          |> where([membership, _principal], membership.group_id == ^group.id)
          |> where([_membership, principal], principal.type == :agent)
          |> select([membership, _principal], membership.principal_uid)
          |> repo.all()

        Store.apply_static_group_member_delta(
          repo,
          group.id,
          :im_group,
          joined -- current,
          current -- joined
        )
      end
    end)
  end

  defp lock_group(repo, group_id) do
    Group
    |> where([group], group.id == ^group_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :group_not_found}
    end
  end

  # Only Agents whose Principal row still exists can hold a membership row;
  # a stale binding observation for a removed Principal is skipped.
  defp joined_agent_uids(repo, metadata) do
    case BindingMembership.joined_agent_uids(metadata) do
      [] ->
        []

      uids ->
        Principal
        |> where([principal], principal.uid in ^uids)
        |> select([principal], principal.uid)
        |> repo.all()
    end
  end
end
