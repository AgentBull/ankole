defmodule Ankole.Conversations.IMGroupMembers do
  @moduledoc """
  Membership writes for `im_group` AuthZ groups shared by IM adapters.

  Entity logic: an Agent joined to a provider room through a binding is a
  member of that room's Principal Group, equal to the human members. Brain
  audience scopes resolve group membership at recall time, so a missing agent
  membership row hides the room's shared knowledge from its own Agent.
  Adapters therefore write human members through this module, which mirrors
  the joined binding Agents in the same transaction.
  """

  alias Ankole.AuthZ.Store
  alias Ankole.Signals.BindingMembership

  @doc """
  Replaces the members of one `im_group` Group with the given human
  Principals plus the Agents of currently joined bindings.

  A group whose bindings all left mirrors no agents, so a caller that first
  marks every binding left can pass an empty list to clear the group.
  """
  @spec replace_members(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def replace_members(group_id, human_uids) when is_list(human_uids) do
    Ankole.Repo.transact_top_level(fn ->
      replace_members_in_tx(group_id, human_uids)
    end)
  end

  @doc "Same as `replace_members/2` inside the caller's transaction."
  def replace_members_in_tx(group_id, human_uids) do
    with {:ok, group} <- lock_group(group_id) do
      uids = Enum.uniq(human_uids ++ joined_agent_uids(group.metadata))
      Store.replace_static_group_members(group.id, :im_group, uids)
    end
  end

  @doc """
  Reconciles only the Agent membership rows of one `im_group` Group with its
  currently joined bindings. Human membership rows stay unchanged.

  Adapters call this after a binding leaves while other bindings remain, so
  the leaving Agent loses membership at the same time a leaving human would.
  """
  @spec reconcile_agent_members(String.t()) :: {:ok, map()} | {:error, term()}
  def reconcile_agent_members(group_id) do
    Ankole.Repo.transact_top_level(fn ->
      reconcile_agent_members_in_tx(group_id)
    end)
  end

  @doc "Same as `reconcile_agent_members/1` inside the caller's transaction."
  def reconcile_agent_members_in_tx(group_id) do
    with {:ok, group} <- lock_group(group_id) do
      joined = joined_agent_uids(group.metadata)

      members =
        Ankole.AuthZ.list_memberships!(
          query: [filter: [group_id: group.id], select: [:principal_uid]]
        )
        |> Enum.map(& &1.principal_uid)

      current = agent_uids(members)

      Store.apply_static_group_member_delta(
        group.id,
        :im_group,
        joined -- current,
        current -- joined
      )
    end
  end

  defp lock_group(group_id) do
    case Ankole.AuthZ.list_groups!(query: [filter: [id: group_id], lock: :for_update]) do
      [group] -> {:ok, group}
      [] -> {:error, :group_not_found}
    end
  end

  # Only Agents whose Principal row still exists can hold a membership row;
  # a stale binding observation for a removed Principal is skipped.
  defp joined_agent_uids(metadata) do
    case BindingMembership.joined_agent_uids(metadata) do
      [] ->
        []

      uids ->
        Ankole.Principals.list_principals!(query: [filter: [uid: [in: uids]], select: [:uid]])
        |> Enum.map(& &1.uid)
    end
  end

  defp agent_uids([]), do: []

  defp agent_uids(uids) do
    Ankole.Principals.list_principals!(
      query: [filter: [uid: [in: uids], type: :agent], select: [:uid]]
    )
    |> Enum.map(& &1.uid)
  end
end
