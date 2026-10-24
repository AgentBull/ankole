defmodule Ankole.CredentialUpgrade do
  @moduledoc false
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site
  # The tenant created by the frozen AddMultiTenancy migration.
  @legacy_tenant_id "019a2b00-0000-7000-8000-000000000001"

  # Use the same classification before and during the schema migration.
  def offboarded_sql(alias_name \\ "p", tenant_scoped? \\ true) do
    restriction_tenant =
      if tenant_scoped?, do: "r.tenant_id = #{alias_name}.tenant_id AND ", else: ""

    event_tenant = if tenant_scoped?, do: "e.tenant_id = #{alias_name}.tenant_id AND ", else: ""

    """
    #{alias_name}.status = 'disabled' AND EXISTS (
      SELECT 1 FROM human_access_restrictions r
      WHERE #{restriction_tenant}r.principal_uid = #{alias_name}.uid
        AND COALESCE(to_jsonb(r)->>'disposition', CASE WHEN
          r.reason IN ('departure', 'enterprise_exit', 'directory_removal', 'departed', 'offboarded', 'self_exit')
          OR (r.source LIKE 'provider:%' AND r.reason <> 'suspended')
          THEN 'offboarded' ELSE 'suspended' END) = 'offboarded'
        AND (r.cleared_at IS NULL OR r.cleared_at > COALESCE((
          SELECT max(e.inserted_at) FROM human_access_events e
          WHERE #{event_tenant}e.principal_uid = #{alias_name}.uid
            AND e.action = 'restore'
        ), '-infinity'::timestamp))
    )
    """
  end

  def table?(repo, name) do
    %{rows: [[exists]]} = repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    exists
  end

  def connect_oidc_evidence!(repo) do
    repo.query!("""
    WITH evidence AS (
      SELECT s.id AS session_id, (array_agg(a.id))[1] AS authentication_id,
        (array_agg(a.revision))[1] AS authentication_revision
      FROM oidc_sessions s JOIN browser_authentications a
        ON a.browser_id = s.browser_id AND a.provider_id = s.provider_id
          AND a.auth_time IS NOT DISTINCT FROM s.auth_time
          AND ((a.tenant_id = s.tenant_id AND a.subject_id = s.principal_uid) OR EXISTS (
            SELECT 1 FROM principal_external_identities i
            WHERE i.tenant_id = s.tenant_id AND i.principal_uid = s.principal_uid
              AND i.provider = a.provider_id AND i.external_id = a.subject_id))
      WHERE s.authentication_id IS NULL
      GROUP BY s.id HAVING count(*) = 1
    )
    UPDATE oidc_sessions s SET authentication_id = e.authentication_id,
      authentication_revision = e.authentication_revision
    FROM evidence e WHERE s.id = e.session_id
    """)

    repo.query!("""
    UPDATE oidc_sessions SET revoked_at = COALESCE(revoked_at, CURRENT_TIMESTAMP)
    WHERE authentication_id IS NULL
    """)
  end

  def preflight!(repo) do
    sources =
      [
        {"saas_accounts",
         """
         SELECT i.principal_uid, lower(btrim(a.email)) AS email
         FROM principal_external_identities i
         JOIN saas_accounts a ON a.id::text = i.external_id
         WHERE i.provider = 'saas-account'
         """},
        {"human_user_local_credentials",
         """
         SELECT h.principal_uid, lower(btrim(h.email)) AS email
         FROM human_users h JOIN human_user_local_credentials c
           ON c.principal_uid = h.principal_uid
         """},
        {"principal_site_credentials",
         """
         SELECT principal_uid, lower(btrim(identifier)) AS email
         FROM principal_site_credentials WHERE provider = 'email_otp'
         """}
      ]
      |> Enum.filter(fn {table, _} -> table?(repo, table) end)
      |> Enum.map(&elem(&1, 1))

    if sources != [] do
      %{rows: [[tenant_scoped?]]} =
        repo.query!("""
        SELECT EXISTS (SELECT 1 FROM pg_attribute
          WHERE attrelid = to_regclass('principals') AND attname = 'tenant_id' AND NOT attisdropped)
        """)

      tenant_id = if tenant_scoped?, do: "p.tenant_id", else: "'#{@legacy_tenant_id}'::uuid"

      tenant_names =
        if tenant_scoped?,
          do: "SELECT id, slug FROM tenants",
          else: "SELECT '#{@legacy_tenant_id}'::uuid AS id, 'default'::text AS slug"

      %{rows: conflicts} =
        repo.query!("""
        WITH tenant_names AS (#{tenant_names}), candidates AS (
          SELECT DISTINCT #{tenant_id} AS tenant_id, c.principal_uid, c.email
          FROM (#{Enum.join(sources, " UNION ALL ")}) c
          JOIN principals p ON p.uid = c.principal_uid
          WHERE NOT (#{offboarded_sql("p", tenant_scoped?)})
        ), conflicts AS (
          SELECT c.* FROM candidates c WHERE c.email IS NULL OR c.email = '' OR
            (SELECT count(DISTINCT x.principal_uid) FROM candidates x
              WHERE x.tenant_id = c.tenant_id AND x.email = c.email) > 1 OR
            (SELECT count(DISTINCT x.email) FROM candidates x
              WHERE x.tenant_id = c.tenant_id AND x.principal_uid = c.principal_uid) > 1
        )
        SELECT c.tenant_id::text, t.slug, c.principal_uid, c.email
        FROM conflicts c JOIN tenant_names t ON t.id = c.tenant_id
        ORDER BY t.slug, c.principal_uid, c.email
        """)

      if conflicts != [] do
        raise "Login credential conflicts. Resolve these bindings before migration " <>
                "(tenant_id, tenant_slug, principal_uid, email): #{inspect(conflicts, limit: :infinity)}"
      end
    end

    :ok
  end
end
