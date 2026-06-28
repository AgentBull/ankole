defmodule Ankole.AuthZ.Snapshot do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Membership
  alias Ankole.AuthZ.Store
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  def build_authorization_snapshot(principal_uid, resource, action, context \\ %{}) do
    with {:ok, [action]} <- Input.normalize_actions([action]),
         {:ok, snapshot} <-
           load_authorization_snapshot(Repo, principal_uid, resource, [action], context) do
      {:ok, Map.put(snapshot, "action", action)}
    end
  end

  def build_authorization_batch_snapshot(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, actions} <- Input.normalize_actions(actions),
         {:ok, snapshot} <-
           load_authorization_snapshot(Repo, principal_uid, resource, actions, context) do
      {:ok, Map.put(snapshot, "actions", actions)}
    end
  end

  defp load_authorization_snapshot(repo, principal_uid, resource, actions, context) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, resource} <- Input.normalize_resource(resource),
         {:ok, context} <- Input.normalize_context(context),
         {:ok, principal} <- Store.fetch_principal(repo, principal_uid) do
      static_group_ids = static_group_ids(repo, principal.uid)
      computed_groups = computed_group_snapshots(repo)
      candidate_group_ids = static_group_ids ++ Enum.map(computed_groups, & &1["id"])
      grants = grant_snapshots(repo, principal.uid, candidate_group_ids, actions)

      {:ok,
       %{
         "principal" => principal_snapshot(principal),
         "staticGroupIds" => static_group_ids,
         "computedGroups" => computed_groups,
         "grants" => grants,
         "resource" => resource,
         "context" => context
       }}
    end
  end

  defp principal_snapshot(%Principal{} = principal) do
    %{
      "uid" => principal.uid,
      "type" => Atom.to_string(principal.type),
      "status" => Atom.to_string(principal.status),
      "displayName" => principal.display_name,
      "avatarUrl" => principal.avatar_url
    }
  end

  defp computed_group_snapshots(repo) do
    Group
    |> where([group], group.kind == :computed)
    |> select([group], %{id: group.id, computed_condition: group.computed_condition})
    |> repo.all()
    |> Enum.map(fn group ->
      %{"id" => group.id, "condition" => group.computed_condition || "false"}
    end)
  end

  defp static_group_ids(repo, principal_uid) do
    Membership
    |> join(:inner, [membership], group in Group, on: group.id == membership.group_id)
    |> where(
      [membership, group],
      membership.principal_uid == ^principal_uid and group.kind == :static
    )
    |> select([membership, _group], membership.group_id)
    |> repo.all()
  end

  defp grant_snapshots(repo, principal_uid, [], actions) do
    Grant
    |> where([grant], grant.action in ^actions)
    |> where([grant], grant.principal_uid == ^principal_uid)
    |> repo.all()
    |> Enum.map(&grant_snapshot/1)
  end

  defp grant_snapshots(repo, principal_uid, candidate_group_ids, actions) do
    Grant
    |> where([grant], grant.action in ^actions)
    |> where(
      [grant],
      grant.principal_uid == ^principal_uid or grant.group_id in ^candidate_group_ids
    )
    |> repo.all()
    |> Enum.map(&grant_snapshot/1)
  end

  defp grant_snapshot(%Grant{} = grant) do
    %{
      "id" => grant.id,
      "principalUid" => grant.principal_uid,
      "groupId" => grant.group_id,
      "resourcePattern" => grant.resource_pattern,
      "action" => grant.action,
      "condition" => grant.condition
    }
  end
end
