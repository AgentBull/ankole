defmodule Ankole.CredentialUpgradeTest do
  use Ankole.DataCase, async: false
  alias Ankole.CredentialUpgrade

  setup do
    schema = "credential_upgrade_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}, public")

    for sql <- [
          "CREATE TABLE tenants (id uuid PRIMARY KEY, slug text NOT NULL)",
          "CREATE TABLE principals (tenant_id uuid, uid text, type text DEFAULT 'human', status text DEFAULT 'active')",
          "CREATE TABLE human_users (tenant_id uuid, principal_uid text, email text)",
          "CREATE TABLE human_user_local_credentials (tenant_id uuid, principal_uid text, password_hash text)",
          "CREATE TABLE principal_external_identities (tenant_id uuid, principal_uid text, provider text, external_id text)",
          "CREATE TABLE human_access_restrictions (tenant_id uuid, principal_uid text, source text, reason text, cleared_at timestamp)",
          "CREATE TABLE human_access_events (tenant_id uuid, principal_uid text, action text, inserted_at timestamp)",
          "CREATE TABLE principal_site_credentials (tenant_id uuid, principal_uid text, provider text, identifier text)",
          "CREATE TABLE saas_accounts (id uuid, email text)"
        ],
        do: Repo.query!(sql)

    tenant = Ecto.UUID.generate()
    Repo.query!("INSERT INTO tenants VALUES ($1::text::uuid, 'upgrade-pod')", [tenant])
    %{upgrade_tenant: tenant}
  end

  test "conflicts report both Humans before touching legacy hashes, mappings, or schema", %{
    upgrade_tenant: tenant
  } do
    person(tenant, "local-owner", "active")
    person(tenant, "site-owner", "active")
    local(tenant, "local-owner", "  RECYCLED@example.com ")
    site(tenant, "site-owner", "recycled@example.com")
    before = snapshot()
    error = assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end

    for value <- [tenant, "upgrade-pod", "local-owner", "site-owner", "recycled@example.com"],
        do: assert(error.message =~ value)

    assert snapshot() == before

    assert [["legacy-hash"]] ==
             Repo.query!("SELECT password_hash FROM human_user_local_credentials").rows
  end

  test "one Human cannot retain two different account-type login emails", %{
    upgrade_tenant: tenant
  } do
    person(tenant, "one-human", "active")
    local(tenant, "one-human", "first@example.com")
    site(tenant, "one-human", "second@example.com")
    before = snapshot()
    error = assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end
    assert error.message =~ "first@example.com"
    assert error.message =~ "second@example.com"
    assert snapshot() == before
  end

  test "equal normalized bindings for the same Human converge without a conflict", %{
    upgrade_tenant: tenant
  } do
    person(tenant, "one-human", "active")
    local(tenant, "one-human", "  SAME@Example.com ")
    site(tenant, "one-human", "same@example.com")
    before = snapshot()
    assert :ok = CredentialUpgrade.preflight!(Repo)
    assert snapshot() == before
  end

  test "only offboarding releases a conflicting email; suspension retains it", %{
    upgrade_tenant: tenant
  } do
    person(tenant, "previous", "disabled")
    person(tenant, "replacement", "active")
    local(tenant, "previous", "reused@example.com")
    site(tenant, "replacement", "reused@example.com")

    Repo.query!(
      "INSERT INTO human_access_restrictions VALUES ($1::text::uuid, 'previous', 'manual', 'suspended', NULL)",
      [tenant]
    )

    assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end
    Repo.query!("UPDATE human_access_restrictions SET reason = 'offboarded'")
    before = snapshot()
    assert :ok = CredentialUpgrade.preflight!(Repo)
    assert snapshot() == before
  end

  test "a restored offboarding cycle does not release a later suspended member's email", %{
    upgrade_tenant: tenant
  } do
    person(tenant, "returned", "disabled")
    person(tenant, "another", "active")
    local(tenant, "returned", "same@example.com")
    site(tenant, "another", "same@example.com")

    Repo.query!(
      "INSERT INTO human_access_restrictions VALUES ($1::text::uuid, 'returned', 'manual', 'offboarded', now() - interval '2 days')",
      [tenant]
    )

    Repo.query!(
      "INSERT INTO human_access_events VALUES ($1::text::uuid, 'returned', 'restore', now() - interval '1 day')",
      [tenant]
    )

    assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end
  end

  test "FOSS checks normalized collisions without any SaaS tables", %{upgrade_tenant: tenant} do
    Repo.query!("DROP TABLE saas_accounts")
    person(tenant, "first", "active")
    person(tenant, "second", "active")
    local(tenant, "first", " SAME@Example.com ")
    local(tenant, "second", "same@example.com")
    before = Repo.query!("SELECT * FROM human_user_local_credentials ORDER BY principal_uid").rows
    error = assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end
    assert error.message =~ "first"
    assert error.message =~ "second"

    assert Repo.query!("SELECT * FROM human_user_local_credentials ORDER BY principal_uid").rows ==
             before
  end

  test "FOSS rejects blank and missing login addresses before changing data", %{
    upgrade_tenant: tenant
  } do
    Repo.query!("DROP TABLE saas_accounts")
    person(tenant, "blank", "active")
    local(tenant, "blank", "   ")
    assert_raise RuntimeError, ~r/blank/, fn -> CredentialUpgrade.preflight!(Repo) end
    Repo.query!("UPDATE human_users SET email = NULL")
    assert_raise RuntimeError, ~r/blank/, fn -> CredentialUpgrade.preflight!(Repo) end

    assert Repo.query!("SELECT password_hash FROM human_user_local_credentials").rows == [
             ["legacy-hash"]
           ]
  end

  test "unscoped legacy credential rows use each Principal's tenant for conflicts", %{
    upgrade_tenant: tenant
  } do
    foreign = Ecto.UUID.generate()
    Repo.query!("INSERT INTO tenants VALUES ($1::text::uuid, 'other-pod')", [foreign])
    person(tenant, "first", "active")
    person(foreign, "foreign", "active")
    local(tenant, "first", "same@example.com")
    local(foreign, "foreign", "same@example.com")
    Repo.query!("ALTER TABLE human_user_local_credentials DROP COLUMN tenant_id")
    assert :ok = CredentialUpgrade.preflight!(Repo)

    person(tenant, "second", "active")

    Repo.query!(
      "INSERT INTO human_users VALUES ($1::text::uuid, 'second', ' SAME@example.com ')",
      [
        tenant
      ]
    )

    Repo.query!("INSERT INTO human_user_local_credentials VALUES ('second', 'legacy-hash')")
    before = snapshot()
    error = assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end
    assert error.message =~ tenant
    refute error.message =~ foreign
    assert snapshot() == before
  end

  test "single-tenant password releases reject conflicts before adding tenant columns", %{
    upgrade_tenant: tenant
  } do
    person(tenant, "first", "active")
    person(tenant, "second", "disabled")
    local(tenant, "first", "same@example.com")
    local(tenant, "second", " SAME@example.com ")

    Repo.query!(
      "INSERT INTO human_access_restrictions VALUES ($1::text::uuid, 'second', 'manual', 'suspended', NULL)",
      [tenant]
    )

    for table <-
          ~w(principals human_users human_user_local_credentials principal_external_identities
                     human_access_restrictions human_access_events principal_site_credentials),
        do: Repo.query!("ALTER TABLE #{table} DROP COLUMN tenant_id")

    before = snapshot()
    error = assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end
    assert error.message =~ "019a2b00-0000-7000-8000-000000000001"
    assert error.message =~ "first"
    assert error.message =~ "second"
    assert snapshot() == before

    Repo.query!("UPDATE human_access_restrictions SET reason = 'offboarded'")
    assert :ok = CredentialUpgrade.preflight!(Repo)
    Repo.query!("UPDATE human_users SET email = ' ' WHERE principal_uid = 'first'")
    assert_raise RuntimeError, ~r/first/, fn -> CredentialUpgrade.preflight!(Repo) end

    assert Repo.query!("SELECT password_hash FROM human_user_local_credentials").rows == [
             ["legacy-hash"],
             ["legacy-hash"]
           ]
  end

  test "preflight succeeds and catches collisions on schemas before human_access_restrictions existed",
       %{upgrade_tenant: tenant} do
    person(tenant, "first", "active")
    local(tenant, "first", "first@example.com")

    Repo.query!("DROP TABLE human_access_restrictions")
    Repo.query!("DROP TABLE human_access_events")
    Repo.query!("DROP TABLE principal_site_credentials")
    Repo.query!("DROP TABLE saas_accounts")

    for table <-
          ~w(principals human_users human_user_local_credentials principal_external_identities),
        do: Repo.query!("ALTER TABLE #{table} DROP COLUMN tenant_id")

    assert :ok = CredentialUpgrade.preflight!(Repo)

    Repo.query!("INSERT INTO principals VALUES ('second', 'human', 'disabled')")
    Repo.query!("INSERT INTO human_users VALUES ('second', ' FIRST@example.com ')")
    Repo.query!("INSERT INTO human_user_local_credentials VALUES ('second', 'legacy-hash')")

    error = assert_raise RuntimeError, fn -> CredentialUpgrade.preflight!(Repo) end
    assert error.message =~ "first"
    assert error.message =~ "second"
  end

  test "offline OIDC migration connects only uniquely evidenced browser authentications", %{
    upgrade_tenant: tenant
  } do
    Repo.query!(
      "CREATE TABLE browser_authentications (id uuid PRIMARY KEY, browser_id uuid, provider_id text, subject_id text, tenant_id uuid, auth_time bigint, revision bigint)"
    )

    Repo.query!(
      "CREATE TABLE oidc_sessions (id uuid PRIMARY KEY, browser_id uuid, provider_id text, principal_uid text, tenant_id uuid, auth_time bigint, authentication_id uuid, authentication_revision bigint, revoked_at timestamp)"
    )

    browser = Ecto.UUID.generate()
    auth = Ecto.UUID.generate()
    session = Ecto.UUID.generate()
    missing = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO browser_authentications VALUES($1::text::uuid,$2::text::uuid,'local-main','member',$3::text::uuid,100,4)",
      [auth, browser, tenant]
    )

    Repo.query!(
      "INSERT INTO oidc_sessions(id,browser_id,provider_id,principal_uid,tenant_id,auth_time) VALUES($1::text::uuid,$2::text::uuid,'local-main','member',$3::text::uuid,100),($4::text::uuid,$2::text::uuid,'local-main','member',$3::text::uuid,200)",
      [session, browser, tenant, missing]
    )

    CredentialUpgrade.connect_oidc_evidence!(Repo)

    assert Repo.query!(
             "SELECT authentication_id::text,authentication_revision,revoked_at FROM oidc_sessions WHERE id=$1::text::uuid",
             [session]
           ).rows == [[auth, 4, nil]]

    assert Repo.query!(
             "SELECT authentication_id,revoked_at IS NOT NULL FROM oidc_sessions WHERE id=$1::text::uuid",
             [missing]
           ).rows == [[nil, true]]

    ambiguous = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO browser_authentications VALUES($1::text::uuid,$2::text::uuid,'local-main','member',$3::text::uuid,100,5)",
      [Ecto.UUID.generate(), browser, tenant]
    )

    Repo.query!(
      "INSERT INTO oidc_sessions(id,browser_id,provider_id,principal_uid,tenant_id,auth_time) VALUES($1::text::uuid,$2::text::uuid,'local-main','member',$3::text::uuid,100)",
      [ambiguous, browser, tenant]
    )

    CredentialUpgrade.connect_oidc_evidence!(Repo)

    assert Repo.query!(
             "SELECT authentication_id,revoked_at IS NOT NULL FROM oidc_sessions WHERE id=$1::text::uuid",
             [ambiguous]
           ).rows == [[nil, true]]
  end

  defp person(tenant, uid, status),
    do:
      Repo.query!(
        "INSERT INTO principals (tenant_id, uid, status) VALUES ($1::text::uuid, $2, $3)",
        [tenant, uid, status]
      )

  defp local(tenant, uid, email) do
    Repo.query!("INSERT INTO human_users VALUES ($1::text::uuid, $2, $3)", [tenant, uid, email])

    Repo.query!(
      "INSERT INTO human_user_local_credentials VALUES ($1::text::uuid, $2, 'legacy-hash')",
      [tenant, uid]
    )
  end

  defp site(tenant, uid, email) do
    id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO saas_accounts VALUES ($1::text::uuid, $2)", [id, email])

    Repo.query!(
      "INSERT INTO principal_external_identities VALUES ($1::text::uuid, $2, 'saas-account', $3)",
      [tenant, uid, id]
    )
  end

  defp snapshot do
    for table <-
          ~w(principals human_users human_user_local_credentials principal_external_identities human_access_restrictions human_access_events principal_site_credentials saas_accounts),
        into: %{} do
      {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY to_jsonb(t)::text").rows}
    end
  end
end
