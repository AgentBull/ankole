defmodule Ankole.Pod.Access.Graph do
  @moduledoc "Reads the ACL anchor graph and projects its effective permissions."
  import Bitwise
  alias Ankole.AuthZ.{Actor, Decision}
  alias Ankole.Repo

  @actions ~w(page_view page_edit page_manage)

  def page_bits(page, reachable) do
    case Map.get(reachable, page.acl_anchor_id) do
      nil -> 0
      bits -> if page.is_acl_anchor, do: bits.self_bits, else: bits.container_bits
    end
  end

  def role_for_actions(bits) do
    cond do
      band(bits, 4) != 0 -> "manage"
      band(bits, 2) != 0 -> "edit"
      band(bits, 1) != 0 -> "view"
      true -> nil
    end
  end

  def action_bit("page_view"), do: 1
  def action_bit("page_edit"), do: 2
  def action_bit("page_manage"), do: 4

  def visibility_ids(reachable, bit \\ 1) do
    Enum.reduce(reachable, {[], []}, fn {id, bits}, {containers, pages} ->
      {if(band(bits.container_bits, bit) != 0, do: [id | containers], else: containers),
       if(band(bits.self_bits, bit) != 0, do: [id | pages], else: pages)}
    end)
  end

  def context_snapshot(%Actor{} = actor, opts \\ []) do
    uid = Actor.uid(actor)

    case Keyword.fetch(opts, :context) do
      {:ok, {%{"principal" => %{"uid" => ^uid}}, _} = context} -> {:ok, context}
      _ -> load_context_snapshot(actor)
    end
  end

  defp load_context_snapshot(actor) do
    with :ok <- Ankole.AuthZ.Checks.ActorGuardrail.check(actor, :pod),
         {:ok, {snapshot, %{"status" => "active"} = evaluated}} <-
           Decision.evaluate_pod_context(actor, Actor.request_context(actor)),
         do: {:ok, {snapshot, evaluated}},
         else: (_ -> {:error, :forbidden})
  end

  def space_bits(%Actor{} = actor) do
    with {:ok, {snapshot, evaluated}} <- context_snapshot(actor) do
      bits = snapshot_space_bits(snapshot, evaluated)

      case Actor.interactive(actor) do
        nil ->
          {:ok, bits}

        human ->
          with {:ok, {snapshot, evaluated}} <- context_snapshot(human),
               do: {:ok, band(bits, snapshot_space_bits(snapshot, evaluated))}
      end
    end
  end

  defp snapshot_space_bits(%{"principal" => %{"membership" => "guest"}}, _), do: 0

  defp snapshot_space_bits(snapshot, evaluated) do
    admin =
      snapshot |> Map.put("resource", "tenant_console:pod_space") |> Map.put("action", "update")

    if match?(%{"status" => "allow"}, Ankole.Kernel.authz_authorize(admin)) do
      7
    else
      satisfied = MapSet.new(evaluated["satisfiedGrantIDs"])
      groups = MapSet.new(evaluated["effectiveGroupIDs"])
      uid = snapshot["principal"]["uid"]

      Enum.reduce(snapshot["grants"], 0, fn grant, bits ->
        subject = grant["principalUID"] == uid or MapSet.member?(groups, grant["groupID"])

        if subject and grant["resourcePattern"] == "pod:space:**" and grant["action"] in @actions and
             (grant["condition"] == "true" or MapSet.member?(satisfied, grant["id"])),
           do: bor(bits, action_bit(grant["action"])),
           else: bits
      end)
    end
  end

  def reachable_anchors(%Actor{} = actor, opts \\ []) do
    with {:ok, reachable} <- reachable_for_actor(actor, opts) do
      case Actor.interactive(actor) do
        nil ->
          {:ok, reachable}

        human ->
          with {:ok, visible} <- reachable_for_actor(human, Keyword.delete(opts, :context)),
               do: {:ok, intersect_reachable(reachable, visible)}
      end
    end
  end

  defp reachable_for_actor(actor, opts) do
    with {:ok, context} <- context_snapshot(actor, opts),
         do: {:ok, graph_rows(query_reachable(Actor.uid(actor), context, opts).rows)}
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

  defp intersect_reachable(reachable, human) do
    Map.new(reachable, fn {id, bits} ->
      other = Map.get(human, id, %{container_bits: 0, self_bits: 0})

      {id,
       %{
         container_bits: band(bits.container_bits, other.container_bits),
         self_bits: band(bits.self_bits, other.self_bits)
       }}
    end)
  end

  defp query_reachable(uid, context, opts) do
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
            SELECT p.parent_anchor_id AS id FROM pages p
            WHERE p.tenant_id = $1::text::uuid AND p.id = d.id
              AND p.parent_anchor_id IS NOT NULL
            UNION ALL
            SELECT source.acl_anchor_id FROM permission_grants g
            JOIN pages source ON source.tenant_id = g.tenant_id AND source.id = g.source_page_id
            WHERE g.tenant_id = $1::text::uuid AND g.target_page_id = d.id
              AND g.source_page_id IS NOT NULL
              AND g.action IN ('page_view', 'page_edit', 'page_manage')
              AND (g.condition = 'true' OR g.id = ANY($2::text[]::uuid[]))
          ) dependency
        ),
        all_anchors AS (
          SELECT id, parent_anchor_id, private_owner_uid, inherit_permissions, deleted_at
          FROM pages
          WHERE tenant_id = $1::text::uuid AND is_acl_anchor = true AND (CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END) IS NULL
          UNION ALL
          SELECT p.id, p.parent_anchor_id, p.private_owner_uid, p.inherit_permissions, p.deleted_at
          FROM dependencies d
          JOIN pages p ON p.tenant_id = $1::text::uuid AND p.id = d.id AND p.is_acl_anchor = true
          WHERE (CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END) IS NOT NULL
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
          SELECT a.id, a.parent_anchor_id, a.private_owner_uid, a.inherit_permissions
          FROM all_anchors a
          LEFT JOIN trashed_anchors t ON t.id = a.id
          WHERE t.id IS NULL AND (NOT $6::boolean OR a.id NOT IN (SELECT id FROM private_anchors))
        ),
        grant_candidates AS (
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.principal_uid = $3::text
            AND g.action IN ('page_view', 'page_edit', 'page_manage') AND g.condition = 'true'
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.group_id = ANY($4::text[]::uuid[])
            AND g.action IN ('page_view', 'page_edit', 'page_manage') AND g.condition = 'true'
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.source_page_id IS NOT NULL
            AND g.condition = 'true' AND g.action IN ('page_view', 'page_edit', 'page_manage')
            AND ((CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END) IS NULL
              OR g.target_page_id IN (SELECT id FROM dependencies))
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.id = ANY($2::text[]::uuid[])
            AND g.action IN ('page_view', 'page_edit', 'page_manage') AND g.condition <> 'true'
        ),
        active_grants AS (
          SELECT
            g.source_page_id,
            CASE g.source_action
              WHEN 'page_view' THEN 1
              WHEN 'page_edit' THEN 2
              WHEN 'page_manage' THEN 4
            END AS req_bit,
            g.target_page_id,
            (g.target_scope = 'container') AS is_container,
            CASE g.action
              WHEN 'page_view' THEN 1
              WHEN 'page_edit' THEN 2
              WHEN 'page_manage' THEN 4
            END AS grant_bit,
            g.resource_pattern
          FROM grant_candidates g
        ),
        seeds (anchor_id, scope, bit) AS (
          SELECT la.id, s.scope, b.bit
          FROM live_anchors la
          CROSS JOIN (VALUES (1), (2), (4)) AS b(bit)
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.parent_anchor_id IS NULL
            AND la.private_owner_uid IS NULL
            AND la.inherit_permissions = true
            AND ($5::integer & b.bit) <> 0

          UNION ALL

          SELECT la.id, s.scope, ag.grant_bit
          FROM live_anchors la
          JOIN active_grants ag
            ON ag.source_page_id IS NULL
           AND ag.target_page_id IS NULL
           AND ag.resource_pattern = ('pod:private:' || la.private_owner_uid || ':**')
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.private_owner_uid IS NOT NULL

          UNION ALL

          SELECT la.id, s.scope, ag.grant_bit
          FROM active_grants ag
          JOIN live_anchors la ON la.id = ag.target_page_id
          CROSS JOIN LATERAL (
            SELECT 'self'::text AS scope
            UNION ALL
            SELECT 'container'::text WHERE ag.is_container
          ) s
          WHERE ag.source_page_id IS NULL
        ),
        edges (src_anchor, src_scope, src_bit, dst_anchor, dst_scope, dst_bit) AS (
          SELECT la.parent_anchor_id, 'container', b.bit, la.id, s.scope, b.bit
          FROM live_anchors la
          CROSS JOIN (VALUES (1), (2), (4)) AS b(bit)
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
          JOIN pages src
            ON src.tenant_id = $1::text::uuid
           AND src.id = ag.source_page_id
           AND src.deleted_at IS NULL
          JOIN live_anchors src_live ON src_live.id = src.acl_anchor_id
          JOIN live_anchors tgt ON tgt.id = ag.target_page_id
          CROSS JOIN LATERAL (
            SELECT 'self'::text AS scope
            UNION ALL
            SELECT 'container'::text WHERE ag.is_container
          ) s
          WHERE ag.source_page_id IS NOT NULL
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
          Keyword.get(opts, :trash_page_ids)
        ]
    )
  end
end
