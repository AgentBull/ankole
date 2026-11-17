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
  @spec replace_members(String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def replace_members(group_id, human_uids, opts \\ []) when is_list(human_uids) do
    Ankole.Repo.transact_top_level(fn ->
      replace_members_in_tx(group_id, human_uids, opts)
    end)
  end

  @doc "Same as `replace_members/3` inside the caller's transaction."
  def replace_members_in_tx(group_id, human_uids, opts \\ []) do
    with {:ok, group} <- lock_group(group_id),
         {:ok, group} <- maybe_update_unmapped_flag(group, opts) do
      uids = Enum.uniq(human_uids ++ joined_agent_uids(group.metadata))
      Store.replace_static_group_members(group.id, :im_group, uids)
    end
  end

  @doc """
  Resolves a roster member according to the binding's `unmatched_sender_policy`.

  When the binding requires `:manual_review`, unmapped external channel members
  are reported as `:unmapped` without creating Human Principals so `group.metadata`
  can record `has_unmapped_members: true`.
  """
  def resolve_roster_member(binding_or_id, attrs) when is_map(attrs) do
    resolve_roster_member_with_policy(roster_policy(binding_or_id), attrs)
  end

  @doc """
  Batch-resolves channel roster items while looking up the binding's
  `unmatched_sender_policy` only once.

  `mapper_fn` maps each raw item to `{:resolve, attrs}`, `:ignored`, or `{:error, reason}`.
  Returns `{:ok, sorted_unique_uids, has_unmapped?}` or `{:error, reason}`.
  """
  def resolve_roster_members(binding_or_id, items, mapper_fn)
      when is_list(items) and is_function(mapper_fn, 1) do
    policy = roster_policy(binding_or_id)

    items
    |> Enum.reduce_while({:ok, {[], false}}, fn item, {:ok, {acc, unmapped?}} ->
      case mapper_fn.(item) do
        :ignored ->
          {:cont, {:ok, {acc, unmapped?}}}

        {:resolve, attrs} when is_map(attrs) ->
          case resolve_roster_member_with_policy(policy, attrs) do
            {:ok, {:mapped, principal}} -> {:cont, {:ok, {[principal.uid | acc], unmapped?}}}
            {:ok, :unmapped} -> {:cont, {:ok, {acc, true}}}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, {uids, unmapped?}} -> {:ok, uids |> Enum.uniq() |> Enum.sort(), unmapped?}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_roster_member_with_policy(:manual_review, attrs) do
    candidates =
      [Map.get(attrs, :external_id) | List.wrap(Map.get(attrs, :external_ids))]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    case Ankole.Principals.match_platform_subject_human(%{
           provider: Map.fetch!(attrs, :provider),
           external_ids: candidates
         }) do
      {:ok, principal} ->
        _ = Ankole.Principals.upsert_platform_subject_human(Map.put(attrs, :uid, principal.uid))
        {:ok, {:mapped, principal}}

      {:error, :not_found} ->
        {:ok, :unmapped}

      {:error, _reason} = error ->
        error
    end
  end

  defp resolve_roster_member_with_policy(_policy, attrs) do
    case Ankole.Principals.upsert_platform_subject_human(attrs) do
      {:ok, observed} -> {:ok, {:mapped, observed.principal}}
      {:error, _reason} = error -> error
    end
  end

  def mark_group_has_unmapped_members(group_id) when is_binary(group_id) do
    Ankole.Repo.transact_top_level(fn ->
      with {:ok, group} <- lock_group(group_id) do
        maybe_update_unmapped_flag(group, has_unmapped_members: true)
      end
    end)
  end

  defp roster_policy(%{unmatched_sender_policy: policy}), do: policy

  defp roster_policy(binding_id) when is_binary(binding_id) do
    case Ankole.Signals.Bindings.get_binding(binding_id) do
      {:ok, %{unmatched_sender_policy: policy}} -> policy
      _ -> :create_standalone
    end
  end

  defp roster_policy(_other), do: :create_standalone

  defp maybe_update_unmapped_flag(group, opts) do
    case Keyword.fetch(opts, :has_unmapped_members) do
      :error ->
        {:ok, group}

      {:ok, unmapped?} when is_boolean(unmapped?) ->
        current = Map.get(group.metadata || %{}, "has_unmapped_members", false)

        if current == unmapped? do
          {:ok, group}
        else
          metadata =
            if unmapped?,
              do: Map.put(group.metadata || %{}, "has_unmapped_members", true),
              else: Map.delete(group.metadata || %{}, "has_unmapped_members")

          Ankole.AuthZ.profile_group(group, %{metadata: metadata})
        end
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
