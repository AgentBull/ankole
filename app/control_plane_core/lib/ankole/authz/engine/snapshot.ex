defmodule Ankole.AuthZ.Snapshot do
  @moduledoc "Projects one tenant-bound PostgreSQL statement into a Kernel authorization snapshot."

  alias Ankole.AuthZ.Input
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @pod_actions ~w(page_view page_write_records page_edit page_manage update)

  def build_authorization_snapshot(principal_uid, resource, action, context \\ %{}) do
    with {:ok, [action]} <- Input.normalize_actions([action]),
         {:ok, snapshot} <-
           load_authorization_snapshot(principal_uid, resource, [action], context) do
      {:ok, Map.put(snapshot, "action", action)}
    end
  end

  def build_authorization_batch_snapshot(principal_uid, resource, actions, context \\ %{}) do
    with {:ok, actions} <- Input.normalize_actions(actions),
         {:ok, snapshot} <- load_authorization_snapshot(principal_uid, resource, actions, context) do
      {:ok, Map.put(snapshot, "actions", actions)}
    end
  end

  def build_pod_context_snapshot(principal_uid, context \\ %{}) do
    with {:ok, uid, context} <- subject(principal_uid, context),
         {:ok, context} <- Input.normalize_context(context),
         {:ok, snapshot} <- load_snapshot(uid, @pod_actions, true) do
      {:ok, Map.put(snapshot, "context", context)}
    end
  end

  @doc false
  def build_condition_preview_snapshot(%Principal{} = principal, group_id, condition) do
    %{
      "principal" => %{
        "uid" => principal.uid,
        "type" => Atom.to_string(principal.type),
        "status" => Atom.to_string(principal.status),
        "membership" => if(principal.membership, do: Atom.to_string(principal.membership)),
        "displayName" => principal.display_name,
        "avatarURL" => principal.avatar_url
      },
      "staticGroupIDs" => [],
      "computedGroups" => [%{"id" => group_id, "condition" => condition}],
      "grants" => [],
      "resource" => "principal_group",
      "action" => "read",
      "context" => %{}
    }
  end

  defp load_authorization_snapshot(principal_uid, resource, actions, context) do
    with {:ok, uid, context} <- subject(principal_uid, context),
         {:ok, resource} <- Input.normalize_resource(resource),
         {:ok, context} <- Input.normalize_context(context),
         {:ok, snapshot} <- load_snapshot(uid, actions, false) do
      {:ok, Map.merge(snapshot, %{"resource" => resource, "context" => context})}
    end
  end

  defp subject(%Ankole.AuthZ.Actor{} = actor, context),
    do:
      {:ok, Ankole.AuthZ.Actor.uid(actor),
       context
       |> Map.merge(Ankole.AuthZ.Actor.request_context(actor))
       |> Map.merge(Map.take(context, ["surface"]))}

  defp subject(uid, context) do
    with {:ok, uid} <- Ankole.PrincipalKey.normalize(uid), do: {:ok, uid, context}
  end

  defp load_snapshot(uid, actions, include_usersets) do
    tenant_id = Repo.tenant_id!()

    result =
      Repo.query!(
        """
        WITH subject AS (
          SELECT uid, type, status, membership, display_name, avatar_url
          FROM principals WHERE tenant_id = $1::text::uuid AND uid = $2
        ), static_groups AS (
          SELECT g.id
          FROM principal_group_memberships m
          JOIN principal_groups g ON g.tenant_id = m.tenant_id AND g.id = m.group_id
          WHERE m.tenant_id = $1::text::uuid AND m.principal_uid = $2 AND g.kind = 'static'
        ), computed_groups AS (
          SELECT id, computed_condition FROM principal_groups
          WHERE tenant_id = $1::text::uuid AND kind = 'computed'
        ), grants AS (
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.action = ANY($3::text[])
            AND g.principal_uid = $2
          UNION ALL
          SELECT g.* FROM permission_grants g
          JOIN static_groups s ON s.id = g.group_id
          WHERE g.tenant_id = $1::text::uuid AND g.action = ANY($3::text[])
          UNION ALL
          SELECT g.* FROM permission_grants g
          JOIN computed_groups c ON c.id = g.group_id
          WHERE g.tenant_id = $1::text::uuid AND g.action = ANY($3::text[])
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.action = ANY($3::text[])
            AND $4::boolean AND g.source_page_id IS NOT NULL AND g.condition <> 'true'
        )
        SELECT jsonb_build_object(
          'principal', jsonb_build_object(
            'uid', p.uid, 'type', p.type, 'status', p.status, 'membership', p.membership,
            'displayName', p.display_name, 'avatarURL', p.avatar_url),
          'staticGroupIDs', COALESCE((SELECT jsonb_agg(id ORDER BY id) FROM static_groups), '[]'),
          'computedGroups', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'id', id, 'condition', COALESCE(computed_condition, 'false')) ORDER BY id)
            FROM computed_groups), '[]'),
          'grants', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'id', id, 'principalUID', principal_uid, 'groupID', group_id,
            'resourcePattern', resource_pattern, 'action', action, 'condition', condition,
            'hasSourcePage', source_page_id IS NOT NULL) ORDER BY id) FROM grants), '[]')
        ) FROM subject p
        """,
        [tenant_id, uid, actions, include_usersets]
      )

    case result.rows do
      [[snapshot]] -> {:ok, snapshot}
      [] -> {:error, :not_found}
    end
  end
end
