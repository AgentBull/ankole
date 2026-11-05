defmodule Ankole.Repo.Migrations.GrantAllHumansColleagueChat do
  use Ecto.Migration

  @all_humans_condition ~s(principal.type == "human" && principal.membership == "member" && principal.status == "active")

  # AI colleagues created before `Agents.create_agent_in_tx/1` seeded a default
  # `all_humans` `"chat"` grant were listed in Meta Ankole and Pod Settings yet
  # omitted from Pod Chat (`GET /api/v2/pod/agents`) and uncallable via A2A or
  # comments unless an operator manually inserted a grant in Site Console.
  # Backfill `all_humans` `"chat"` on `agent:<uid>` only for AI colleagues that
  # do not already have any `"chat"` grant on `agent:<uid>`, preserving
  # colleagues whose chat audience an operator explicitly customized.
  def up do
    execute(fn -> backfill!(repo()) end)
  end

  def down do
    execute("""
    DELETE FROM permission_grants
    WHERE action = 'chat'
      AND metadata->>'built_in' = 'ai_colleague_default_chat'
    """)
  end

  def backfill!(repo) do
    tenants =
      repo.query!("SELECT DISTINCT tenant_id::text FROM agents WHERE type = 'ai_colleague'").rows

    Enum.each(tenants, fn [tenant_id] ->
      group_id = ensure_all_humans_group!(repo, tenant_id)

      ungranted_uids =
        repo.query!(
          """
          SELECT a.uid
          FROM agents a
          WHERE a.tenant_id = $1::text::uuid
            AND a.type = 'ai_colleague'
            AND NOT EXISTS (
              SELECT 1
              FROM permission_grants pg
              WHERE pg.tenant_id = a.tenant_id
                AND pg.resource_pattern = 'agent:' || a.uid
                AND pg.action = 'chat'
            )
          ORDER BY a.uid ASC
          """,
          [tenant_id]
        ).rows

      Enum.each(ungranted_uids, fn [uid] ->
        repo.query!(
          """
          INSERT INTO permission_grants (
            tenant_id, id, group_id, resource_pattern, action, condition,
            description, metadata, inserted_at, updated_at
          )
          VALUES (
            $1::text::uuid, $2::text::uuid, $3::text::uuid, $4, 'chat', 'true',
            'Default Pod member chat access for AI colleague',
            '{"built_in": "ai_colleague_default_chat"}'::jsonb,
            now(), now()
          )
          ON CONFLICT (group_id, resource_pattern, action, condition)
            WHERE group_id IS NOT NULL
            DO NOTHING
          """,
          [tenant_id, Ankole.Ecto.UUIDv7.autogenerate(), group_id, "agent:" <> uid]
        )
      end)
    end)
  end

  defp ensure_all_humans_group!(repo, tenant_id) do
    repo.query!(
      """
      INSERT INTO principal_groups (
        id, tenant_id, name, display_name, domain, kind, built_in,
        computed_condition, description, metadata, inserted_at, updated_at
      )
      VALUES (
        $1::text::uuid, $2::text::uuid, 'all_humans', 'All Humans',
        'operator', 'computed', true, $3,
        'Computed group for active human Principals', '{}'::jsonb, now(), now()
      )
      ON CONFLICT (tenant_id, name) DO NOTHING
      """,
      [Ankole.Ecto.UUIDv7.autogenerate(), tenant_id, @all_humans_condition]
    )

    case repo.query!(
           """
           SELECT id::text, kind, built_in, computed_condition
           FROM principal_groups
           WHERE tenant_id = $1::text::uuid AND name = 'all_humans'
           """,
           [tenant_id]
         ).rows do
      [[id, "computed", true, @all_humans_condition]] ->
        id

      other ->
        raise Ecto.MigrationError,
              "Expected built-in computed all_humans group for tenant #{tenant_id}, got: #{inspect(other)}"
    end
  end
end
