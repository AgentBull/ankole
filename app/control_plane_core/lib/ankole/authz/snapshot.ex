defmodule Ankole.AuthZ.Snapshot do
  @moduledoc """
  Projects the AuthZ rows of one decision into the kernel snapshot.

  This read model runs for each authorization check. It selects maps and
  values from grants, groups, and memberships; it does not load resources.
  """

  import Ecto.Query, warn: false

  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Membership
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  def build_authorization_snapshot(principal_uid, resource, action, context \\ %{}) do
    with {:ok, [action]} <- Input.normalize_actions([action]),
         {:ok, snapshot} <-
           load_authorization_snapshot(principal_uid, resource, [action], context) do
      {:ok, Map.put(snapshot, "action", action)}
    end
  end

  def build_authorization_batch_snapshot(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, actions} <- Input.normalize_actions(actions),
         {:ok, snapshot} <-
           load_authorization_snapshot(principal_uid, resource, actions, context) do
      {:ok, Map.put(snapshot, "actions", actions)}
    end
  end

  @doc false
  def build_condition_preview_snapshot(%Principal{} = principal, group_id, condition) do
    %{
      "principal" => principal_snapshot(principal),
      "staticGroupIDs" => [],
      "computedGroups" => [%{"id" => group_id, "condition" => condition}],
      "grants" => [],
      "resource" => "principal_group",
      "action" => "read",
      "context" => %{}
    }
  end

  defp load_authorization_snapshot(principal_uid, resource, actions, context) do
    with {:ok, principal_uid} <- Principals.normalize_uid(principal_uid),
         {:ok, resource} <- Input.normalize_resource(resource),
         {:ok, context} <- Input.normalize_context(context),
         {:ok, principal} <- fetch_principal(principal_uid) do
      Repo.with_tenant(principal.tenant_id, fn ->
        static_group_ids = static_group_ids(principal.uid)
        computed_groups = computed_group_snapshots()
        candidate_group_ids = static_group_ids ++ Enum.map(computed_groups, & &1["id"])
        grants = grant_snapshots(principal.uid, candidate_group_ids, actions)

        {:ok,
         %{
           "principal" => principal_snapshot(principal),
           "staticGroupIDs" => static_group_ids,
           "computedGroups" => computed_groups,
           "grants" => grants,
           "resource" => resource,
           "context" => context
         }}
      end)
    end
  end

  # A Principal UID is unique across tenants; its row selects the tenant.
  defp fetch_principal(principal_uid) do
    case Repo.across_tenants(fn -> Principals.get_principal_across_tenants(principal_uid) end) do
      {:ok, %Principal{} = principal} -> {:ok, principal}
      {:ok, nil} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp principal_snapshot(%Principal{} = principal) do
    %{
      "uid" => principal.uid,
      "type" => Atom.to_string(principal.type),
      "status" => Atom.to_string(principal.status),
      "displayName" => principal.display_name,
      "avatarURL" => principal.avatar_url
    }
  end

  defp computed_group_snapshots() do
    Group
    |> where([group], group.kind == :computed)
    |> select([group], %{id: group.id, computed_condition: group.computed_condition})
    |> Repo.all()
    |> Enum.map(fn group ->
      %{"id" => group.id, "condition" => group.computed_condition || "false"}
    end)
  end

  defp static_group_ids(principal_uid) do
    Membership
    |> join(:inner, [membership], group in Group, on: group.id == membership.group_id)
    |> where(
      [membership, group],
      membership.principal_uid == ^principal_uid and group.kind == :static
    )
    |> select([membership, _group], membership.group_id)
    |> Repo.all()
  end

  defp grant_snapshots(principal_uid, [], actions) do
    Grant
    |> where([grant], grant.action in ^actions)
    |> where([grant], grant.principal_uid == ^principal_uid)
    |> select_grant_snapshot()
    |> Repo.all()
  end

  defp grant_snapshots(principal_uid, candidate_group_ids, actions) do
    Grant
    |> where([grant], grant.action in ^actions)
    |> where(
      [grant],
      grant.principal_uid == ^principal_uid or grant.group_id in ^candidate_group_ids
    )
    |> select_grant_snapshot()
    |> Repo.all()
  end

  defp select_grant_snapshot(query) do
    select(query, [grant], %{
      "id" => grant.id,
      "principalUID" => grant.principal_uid,
      "groupID" => grant.group_id,
      "resourcePattern" => grant.resource_pattern,
      "action" => grant.action,
      "condition" => grant.condition
    })
  end
end
