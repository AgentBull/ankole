defmodule Ankole.Files.Access.Graph do
  @moduledoc "Reads the ACL anchor graph and projects its effective permissions."
  import Bitwise
  alias Ankole.AuthZ.{Actor, Decision}
  alias Ankole.Repo

  @actions ~w(node_view node_contribute node_edit node_manage node_comment)

  def page_bits(page, reachable) do
    case Map.get(reachable, page.acl_anchor_id) do
      nil -> 0
      bits -> if page.is_acl_anchor, do: bits.self_bits, else: bits.container_bits
    end
  end

  def role_for_actions(bits) do
    cond do
      band(bits, 8) != 0 -> "manage"
      band(bits, 4) != 0 -> "edit"
      band(bits, 18) != 0 -> "contribute"
      band(bits, 1) != 0 -> "view"
      true -> nil
    end
  end

  def action_bit("node_view"), do: 1
  def action_bit("node_contribute"), do: 2
  def action_bit("node_edit"), do: 4
  def action_bit("node_manage"), do: 8
  def action_bit("node_comment"), do: 16

  def project_permissions(page, bits) do
    actions = for action <- @actions, band(bits, action_bit(action)) != 0, do: action

    visited_at =
      if match?(%Ash.NotLoaded{}, Map.get(page, :visited_at)),
        do: nil,
        else: Map.get(page, :visited_at)

    Map.merge(page, %{role: role_for_actions(bits), actions: actions, visited_at: visited_at})
  end

  def visibility_ids(reachable, required_bits \\ 1) do
    Enum.reduce(reachable, {[], []}, fn {id, bits}, {containers, pages} ->
      {if(band(bits.container_bits, required_bits) == required_bits,
         do: [id | containers],
         else: containers
       ), if(band(bits.self_bits, required_bits) == required_bits, do: [id | pages], else: pages)}
    end)
  end

  def context_snapshot(%Actor{} = actor, opts \\ []) do
    uid = Actor.uid(actor)

    case Keyword.fetch(opts, :context) do
      {:ok, {%{"executionUID" => ^uid}, _} = context} -> {:ok, context}
      _ -> load_context_snapshot(actor)
    end
  end

  defp load_context_snapshot(actor) do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :drive),
         {:ok, {snapshot, %{"status" => "active"} = evaluated}} <-
           Decision.evaluate_drive_context(actor, Actor.request_context(actor)),
         do:
           {:ok,
            {Map.put(snapshot, "canManageSpace", can_manage_space?(actor, snapshot)), evaluated}},
         else: (_ -> {:error, :forbidden})
  end

  def space_bits(%Actor{} = actor) do
    with {:ok, {snapshot, evaluated}} <- context_snapshot(actor) do
      bits = snapshot_space_bits(snapshot, evaluated)

      {:ok, bits}
    end
  end

  def navigation_access(%Actor{} = actor) do
    with {:ok, {snapshot, evaluated} = context} <- context_snapshot(actor) do
      {:ok,
       %{
         reachable:
           graph_rows(
             query_reachable(Ankole.Principals.authority_uid(Actor.uid(actor)), context, []).rows
           ),
         space_bits: snapshot_space_bits(snapshot, evaluated),
         can_manage_space: space_manager?(snapshot)
       }}
    end
  end

  @doc "Detects changes in the executing Principal, grants, groups and conversation membership."
  def context_signature(%Actor{} = actor) do
    with {:ok, {snapshot, evaluated}} <- context_snapshot(actor) do
      permissions =
        {Map.take(snapshot["principal"], ~w(uid type status membership)),
         Enum.sort_by(snapshot["grants"], & &1["id"]), Enum.sort(evaluated["satisfiedGrantIDs"]),
         Enum.sort(evaluated["effectiveGroupIDs"]), space_manager?(snapshot),
         Enum.sort(Map.get(snapshot, "conversationIDs", []))}

      {:ok, :crypto.hash(:sha256, :erlang.term_to_binary(permissions, [:deterministic]))}
    end
  end

  defp space_manager?(snapshot), do: snapshot["canManageSpace"] == true

  defp can_manage_space?(actor, snapshot) do
    if Actor.uid(actor) == snapshot["principal"]["uid"] do
      snapshot =
        snapshot
        |> Map.put("resource", "tenant_console:drive_space")
        |> Map.put("action", "update")

      match?(%{"status" => "allow"}, Ankole.Kernel.authz_authorize(snapshot))
    else
      Ankole.AuthZ.authorize(actor, "tenant_console:drive_space", "update") == :ok
    end
  end

  defp snapshot_space_bits(%{"principal" => %{"membership" => "guest"}}, _), do: 0

  defp snapshot_space_bits(snapshot, evaluated) do
    if space_manager?(snapshot) do
      31
    else
      satisfied = MapSet.new(evaluated["satisfiedGrantIDs"])
      groups = MapSet.new(evaluated["effectiveGroupIDs"])
      uid = snapshot["principal"]["uid"]

      Enum.reduce(snapshot["grants"], 0, fn grant, bits ->
        subject = grant["principalUID"] == uid or MapSet.member?(groups, grant["groupID"])

        if subject and grant["resourcePattern"] == "drive:space:**" and
             grant["action"] in @actions and
             (grant["condition"] == "true" or MapSet.member?(satisfied, grant["id"])),
           do: bor(bits, action_bit(grant["action"])),
           else: bits
      end)
    end
  end

  def reachable_anchors(%Actor{} = actor, opts \\ []) do
    reachable_for_actor(actor, opts)
  end

  defp reachable_for_actor(actor, opts) do
    with {:ok, context} <- context_snapshot(actor, opts),
         do:
           {:ok,
            graph_rows(
              query_reachable(Ankole.Principals.authority_uid(Actor.uid(actor)), context, opts).rows
            )}
  end

  def reachable_trashed(subject, page_ids, opts \\ []),
    do: reachable_anchors(subject, Keyword.put(opts, :trash_page_ids, page_ids))

  defp graph_params(uid, {snapshot, evaluated}) do
    [
      Repo.tenant_id!(),
      evaluated["satisfiedGrantIDs"],
      uid,
      evaluated["effectiveGroupIDs"],
      snapshot_space_bits(snapshot, evaluated),
      snapshot["principal"]["membership"] == "guest"
    ]
  end

  defp graph_rows(rows) do
    Map.new(rows, fn [id, container, own] ->
      {id, %{container_bits: container, self_bits: own}}
    end)
  end

  defp query_reachable(uid, context, opts) do
    # A UNION between full and targeted reads loses the column statistics of
    # deleted_at. PostgreSQL then estimates millions of trashed anchors even
    # when none exist. Keep the full scan direct and targeted reads keyed by
    # their dependency closure; all interpolated SQL is fixed here.
    anchors_query =
      if is_nil(Keyword.get(opts, :target_ids)) and is_nil(Keyword.get(opts, :trash_page_ids)) do
        """
        SELECT id, parent_anchor_id, private_owner_uid, conversation_id, inherit_permissions, deleted_at
        FROM drive_nodes
        WHERE tenant_id = $1::text::uuid AND is_acl_anchor = true
        """
      else
        """
        SELECT p.id, p.parent_anchor_id, p.private_owner_uid, p.conversation_id, p.inherit_permissions, p.deleted_at
        FROM dependencies d
        JOIN drive_nodes p ON p.tenant_id = $1::text::uuid AND p.id = d.id AND p.is_acl_anchor = true
        """
      end

    Repo.query!(
      """
      SELECT graph.anchor_id, graph.container_bits, graph.self_bits
      FROM unnest(COALESCE($9::text[], ARRAY[$8::text])) AS candidate(trash_id)
      CROSS JOIN LATERAL (
        WITH RECURSIVE
        dependencies (id) AS (
          SELECT unnest((CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END)::uuid[])
          UNION
          SELECT dependency.id
          FROM dependencies d
          CROSS JOIN LATERAL (
            SELECT p.parent_anchor_id AS id FROM drive_nodes p
            WHERE p.tenant_id = $1::text::uuid AND p.id = d.id
              AND p.parent_anchor_id IS NOT NULL
            UNION ALL
            SELECT source.acl_anchor_id FROM permission_grants g
            JOIN drive_nodes source ON source.tenant_id = g.tenant_id AND source.id = g.source_node_id
            WHERE g.tenant_id = $1::text::uuid AND g.target_node_id = d.id
              AND g.source_node_id IS NOT NULL
              AND g.action IN ('node_view', 'node_contribute', 'node_edit', 'node_manage', 'node_comment')
              AND (g.condition = 'true' OR g.id = ANY($2::text[]::uuid[]))
          ) dependency
        ),
        all_anchors AS (
          #{anchors_query}
        ),
        trashed_anchors AS (
          SELECT id FROM all_anchors WHERE deleted_at IS NOT NULL AND id <> COALESCE((CASE WHEN $9::text[] IS NULL THEN $8::text ELSE candidate.trash_id END)::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
          UNION
          SELECT c.id
          FROM all_anchors c
          JOIN trashed_anchors t ON c.parent_anchor_id = t.id
        ),
        private_anchors AS (
          SELECT id FROM all_anchors WHERE private_owner_uid IS NOT NULL
          UNION
          SELECT c.id FROM all_anchors c JOIN private_anchors p ON c.parent_anchor_id = p.id
        ),
        live_anchors AS (
          SELECT a.id, a.parent_anchor_id, a.private_owner_uid, a.conversation_id, a.inherit_permissions
          FROM all_anchors a
          LEFT JOIN trashed_anchors t ON t.id = a.id
          WHERE t.id IS NULL AND (NOT $6::boolean OR a.id NOT IN (SELECT id FROM private_anchors))
        ),
        grant_candidates AS (
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.principal_uid = $3::text
            AND g.action IN ('node_view', 'node_contribute', 'node_edit', 'node_manage', 'node_comment') AND g.condition = 'true'
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.group_id = ANY($4::text[]::uuid[])
            AND g.action IN ('node_view', 'node_contribute', 'node_edit', 'node_manage', 'node_comment') AND g.condition = 'true'
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.source_node_id IS NOT NULL
            AND g.condition = 'true' AND g.action IN ('node_view', 'node_contribute', 'node_edit', 'node_manage', 'node_comment')
            AND ((CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END) IS NULL
              OR g.target_node_id IN (SELECT id FROM dependencies))
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.id = ANY($2::text[]::uuid[])
            AND g.action IN ('node_view', 'node_contribute', 'node_edit', 'node_manage', 'node_comment') AND g.condition <> 'true'
        ),
        active_grants AS (
          SELECT
            g.source_node_id,
            CASE g.source_action
              WHEN 'node_view' THEN 1
              WHEN 'node_contribute' THEN 2
              WHEN 'node_edit' THEN 4
              WHEN 'node_manage' THEN 8
              WHEN 'node_comment' THEN 16
            END AS req_bit,
            g.target_node_id,
            (g.target_scope = 'container') AS is_container,
            CASE g.action
              WHEN 'node_view' THEN 1
              WHEN 'node_contribute' THEN 2
              WHEN 'node_edit' THEN 4
              WHEN 'node_manage' THEN 8
              WHEN 'node_comment' THEN 16
            END AS grant_bit,
            g.resource_pattern
          FROM grant_candidates g
        ),
        seeds (anchor_id, scope, bit) AS (
          SELECT la.id, s.scope, b.bit
          FROM live_anchors la
          CROSS JOIN (VALUES (1), (2), (4), (8), (16)) AS b(bit)
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.parent_anchor_id IS NULL
            AND la.private_owner_uid IS NULL
            AND la.conversation_id IS NULL
            AND la.inherit_permissions = true
            AND ($5::integer & b.bit) <> 0

          UNION ALL

          SELECT la.id, s.scope, b.bit
          FROM live_anchors la
          CROSS JOIN (VALUES (1), (2)) AS b(bit)
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.conversation_id = ANY($10::text[]::uuid[])

          UNION ALL

          SELECT la.id, s.scope, ag.grant_bit
          FROM live_anchors la
          JOIN active_grants ag
            ON ag.source_node_id IS NULL
           AND ag.target_node_id IS NULL
           AND ag.resource_pattern = ('drive:private:' || la.private_owner_uid || ':**')
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.private_owner_uid IS NOT NULL

          UNION ALL

          SELECT la.id, s.scope, ag.grant_bit
          FROM active_grants ag
          JOIN live_anchors la ON la.id = ag.target_node_id
          CROSS JOIN LATERAL (
            SELECT 'self'::text AS scope
            UNION ALL
            SELECT 'container'::text WHERE ag.is_container
          ) s
          WHERE ag.source_node_id IS NULL
        ),
        edges (src_anchor, src_scope, src_bit, dst_anchor, dst_scope, dst_bit) AS (
          SELECT la.parent_anchor_id, 'container', b.bit, la.id, s.scope, b.bit
          FROM live_anchors la
          CROSS JOIN (VALUES (1), (2), (4), (8), (16)) AS b(bit)
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.parent_anchor_id IS NOT NULL
            AND la.inherit_permissions = true

          UNION ALL

          SELECT
            src.acl_anchor_id,
            CASE WHEN src.is_acl_anchor THEN 'self' ELSE 'container' END,
            ag.req_bit,
            tgt.id,
            s.scope,
            ag.grant_bit
          FROM active_grants ag
          JOIN drive_nodes src
            ON src.tenant_id = $1::text::uuid
           AND src.id = ag.source_node_id
           AND src.deleted_at IS NULL
          JOIN live_anchors src_live ON src_live.id = src.acl_anchor_id
          JOIN live_anchors tgt ON tgt.id = ag.target_node_id
          CROSS JOIN LATERAL (
            SELECT 'self'::text AS scope
            UNION ALL
            SELECT 'container'::text WHERE ag.is_container
          ) s
          WHERE ag.source_node_id IS NOT NULL
        ),
        reach (anchor_id, scope, bit) AS (
          SELECT anchor_id, scope, bit FROM seeds
          UNION
          SELECT e.dst_anchor, e.dst_scope, e.dst_bit
          FROM reach r
          JOIN edges e
            ON e.src_anchor = r.anchor_id
           AND e.src_scope = r.scope
           AND e.src_bit = r.bit
        )
        SELECT
          anchor_id::text,
          COALESCE(bit_or(bit) FILTER (WHERE scope = 'container'), 0) AS container_bits,
          bit_or(bit) AS self_bits
        FROM reach
        GROUP BY anchor_id
      ) graph
      WHERE $9::text[] IS NULL OR graph.anchor_id = candidate.trash_id
      """,
      graph_params(uid, context) ++
        [
          Keyword.get(opts, :target_ids),
          Keyword.get(opts, :trash_page_id),
          Keyword.get(opts, :trash_page_ids),
          Map.get(elem(context, 0), "conversationIDs", [])
        ]
    )
  end
end
