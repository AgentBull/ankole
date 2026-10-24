defmodule Ankole.Ecto.AuthnMigrationTest do
  use Ankole.DataCase, async: false

  @migration Ankole.Repo.Migrations.CreateAuthnSiteCredentialsAndPodAdmin
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261024010000_create_authn_site_credentials_and_pod_admin.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "authn_upgrade_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}, public")

    for sql <- [
          "CREATE TABLE tenants (id uuid PRIMARY KEY, slug text NOT NULL, deleting_at timestamp)",
          "CREATE TABLE principals (tenant_id uuid, uid text PRIMARY KEY, type text DEFAULT 'human', membership text DEFAULT 'member', status text DEFAULT 'active', access_version bigint DEFAULT 1, UNIQUE (tenant_id, uid))",
          "CREATE TABLE human_users (tenant_id uuid, principal_uid text, email text, mobile text, UNIQUE (tenant_id, principal_uid))",
          "CREATE TABLE human_user_local_credentials (tenant_id uuid, principal_uid text, password_hash text)",
          "CREATE TABLE human_access_restrictions (id uuid PRIMARY KEY, tenant_id uuid, principal_uid text, source text, reason text, cleared_at timestamp)",
          "CREATE UNIQUE INDEX human_access_restrictions_active_index ON human_access_restrictions (tenant_id, principal_uid, source, reason) WHERE cleared_at IS NULL",
          "CREATE TABLE human_access_events (id uuid PRIMARY KEY, tenant_id uuid, principal_uid text, operation_id text, source text, action text, reason text, previous_status text, status text, access_version bigint, inserted_at timestamp)",
          "CREATE TABLE browser_sessions (id uuid PRIMARY KEY)",
          "CREATE TABLE browser_login_transactions (id uuid PRIMARY KEY, password_ticket jsonb)",
          "CREATE TABLE browser_authentications (id uuid PRIMARY KEY, provider_id text, tenant_id uuid, subject_id text, browser_id uuid, revision bigint DEFAULT 1, auth_time bigint, inserted_at timestamp DEFAULT now(), revoked_at timestamp)",
          "CREATE TABLE principal_external_identities (id uuid PRIMARY KEY, tenant_id uuid, principal_uid text, provider text, external_id text, metadata jsonb DEFAULT '{}', inserted_at timestamp DEFAULT now(), updated_at timestamp DEFAULT now(), UNIQUE (tenant_id, provider, external_id))",
          "CREATE TABLE app_configurations (tenant_id uuid, key text, value jsonb)",
          "CREATE TABLE oidc_clients (id uuid PRIMARY KEY, tenant_id uuid, allowed_identity_provider_ids text[])",
          "CREATE TABLE oidc_sessions (id uuid PRIMARY KEY, provider_id text, tenant_id uuid, principal_uid text, browser_id uuid, auth_time bigint, authentication_id uuid, authentication_revision bigint, revoked_at timestamp)",
          "CREATE TABLE principal_groups (id uuid PRIMARY KEY, tenant_id uuid, name text, display_name text, kind text, built_in boolean, inserted_at timestamp, updated_at timestamp, UNIQUE (tenant_id, name))",
          "CREATE TABLE permission_grants (id uuid PRIMARY KEY, tenant_id uuid, group_id uuid, resource_pattern text, action text, condition text, inserted_at timestamp, updated_at timestamp, UNIQUE (tenant_id, group_id, resource_pattern, action, condition))",
          "CREATE TABLE principal_group_memberships (tenant_id uuid, group_id uuid, principal_uid text, inserted_at timestamp, PRIMARY KEY (tenant_id, group_id, principal_uid))",
          "CREATE TABLE identity_directory_states (tenant_id uuid)"
        ],
        do: Repo.query!(sql)

    :ok
  end

  test "the legacy migration preserves suspension, releases departure, and backfills only determined administrators" do
    tenant = tenant("governed")
    admin = person(tenant, "active", "admin@example.com")
    suspended = person(tenant, "disabled", "suspended@example.com")
    departed = person(tenant, "disabled", "departed@example.com")

    for {uid, reason} <- [{suspended, "suspended"}, {departed, "offboarded"}] do
      Repo.query!(
        "INSERT INTO human_access_restrictions VALUES ($1::text::uuid,$2::text::uuid,$3,'manual',$4,NULL)",
        [Ecto.UUID.generate(), tenant, uid, reason]
      )
    end

    site_admin = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO principal_groups (id,tenant_id,name,built_in) VALUES ($1::text::uuid,$2::text::uuid,'siteadmin',true)",
      [site_admin, tenant]
    )

    Repo.query!(
      "INSERT INTO principal_group_memberships VALUES ($1::text::uuid,$2::text::uuid,$3,now())",
      [tenant, site_admin, admin]
    )

    for {uid, provider, subject} <- [
          {suspended, "lark-main", "Suspended.Alias@Example.com"},
          {suspended, "lark-main", "stable-suspended-id"},
          {admin, "lark-main", "sole-subject@enterprise.example"},
          {departed, "lark-main", "Departed.Alias@Example.com"},
          {departed, "lark-main", "immutable-lark-id"},
          {departed, "enterprise-oidc", "stable-subject@example.com"},
          {departed, "lark", "sole-departed@example.com"}
        ] do
      Repo.query!(
        "INSERT INTO principal_external_identities (id,tenant_id,principal_uid,provider,external_id) VALUES ($1::text::uuid,$2::text::uuid,$3,$4,$5)",
        [Ecto.UUID.generate(), tenant, uid, provider, subject]
      )
    end

    Repo.query!(
      "INSERT INTO app_configurations VALUES ($1::text::uuid,'principals.identity_providers.active',$2)",
      [
        tenant,
        %{
          "type" => "plaintext",
          "value" => [
            %{"provider_id" => "local-main", "adapter_id" => "local"},
            %{"provider_id" => "lark-main", "adapter_id" => "lark"}
          ]
        }
      ]
    )

    Repo.query!(
      "INSERT INTO app_configurations VALUES ($1::text::uuid,'principals.local_password.test','{}')",
      [tenant]
    )

    Repo.query!(
      "INSERT INTO oidc_clients VALUES ($1::text::uuid, $2::text::uuid, ARRAY['local-main','lark-main'])",
      [Ecto.UUID.generate(), tenant]
    )

    Repo.query!(
      "INSERT INTO oidc_sessions (id,provider_id,tenant_id) VALUES ($1::text::uuid,'local-main',$2::text::uuid)",
      [
        Ecto.UUID.generate(),
        tenant
      ]
    )

    Repo.query!(
      "INSERT INTO browser_authentications (id,provider_id,tenant_id,subject_id) VALUES ($1::text::uuid,'local-main',$2::text::uuid,$3)",
      [Ecto.UUID.generate(), tenant, admin]
    )

    other_tenant = tenant("enterprise")
    other = person(other_tenant, "active", "other@example.com")

    Repo.query!(
      "INSERT INTO app_configurations VALUES ($1::text::uuid,'principals.identity_providers.active',$2)",
      [
        other_tenant,
        %{
          "type" => "plaintext",
          "value" => [%{"provider_id" => "local-main", "adapter_id" => "oidc"}]
        }
      ]
    )

    Repo.query!(
      "INSERT INTO oidc_clients VALUES ($1::text::uuid,$2::text::uuid,ARRAY['local-main'])",
      [Ecto.UUID.generate(), other_tenant]
    )

    Repo.query!(
      "INSERT INTO oidc_sessions (id,provider_id,tenant_id) VALUES ($1::text::uuid,'local-main',$2::text::uuid)",
      [Ecto.UUID.generate(), other_tenant]
    )

    Repo.query!(
      "INSERT INTO browser_authentications (id,provider_id,tenant_id,subject_id) VALUES ($1::text::uuid,'local-main',$2::text::uuid,$3)",
      [Ecto.UUID.generate(), other_tenant, other]
    )

    empty_departure = person(tenant, "disabled", nil)

    Repo.query!("UPDATE human_users SET mobile = NULL WHERE principal_uid = $1", [empty_departure])

    Repo.query!(
      "INSERT INTO human_access_restrictions VALUES ($1::text::uuid,$2::text::uuid,$3,'manual','offboarded',NULL)",
      [Ecto.UUID.generate(), tenant, empty_departure]
    )

    solo_tenant = tenant("solo")
    solo = person(solo_tenant, "active", "solo@example.com")
    ambiguous = tenant("ambiguous")
    person(ambiguous, "active", "first@example.com")
    person(ambiguous, "active", "second@example.com")
    managed = tenant("managed")
    person(managed, "active", "managed@example.com")
    Repo.query!("INSERT INTO identity_directory_states VALUES ($1::text::uuid)", [managed])

    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_024_010_000,
      @migration,
      :forward,
      :up,
      :up,
      log: false
    )

    assert Repo.query!(
             "SELECT count(*) FROM human_access_events WHERE cardinality(released_identifiers) = 0"
           ).rows == [[0]]

    credentials =
      Repo.query!("SELECT principal_uid,identifier FROM principal_site_credentials").rows
      |> Map.new(fn [uid, email] -> {uid, email} end)

    assert credentials[admin] == "admin@example.com"
    assert credentials[suspended] == "suspended@example.com"
    refute Map.has_key?(credentials, departed)

    assert Repo.query!("SELECT email,mobile FROM human_users WHERE principal_uid=$1", [departed]).rows ==
             [[nil, nil]]

    assert Repo.query!(
             "SELECT provider,external_id FROM principal_external_identities WHERE principal_uid=$1 ORDER BY provider",
             [departed]
           ).rows == [
             ["enterprise-oidc", "stable-subject@example.com"],
             ["lark-main", "immutable-lark-id"]
           ]

    assert Repo.query!(
             "SELECT provider,external_id FROM principal_external_identities WHERE principal_uid=$1 ORDER BY provider",
             [suspended]
           ).rows == [
             ["email", "suspended.alias@example.com"],
             ["lark-main", "stable-suspended-id"]
           ]

    assert Repo.query!(
             "SELECT provider,external_id FROM principal_external_identities WHERE principal_uid=$1",
             [admin]
           ).rows == [["lark-main", "sole-subject@enterprise.example"]]

    [[released]] =
      Repo.query!(
        "SELECT released_identifiers FROM human_access_events WHERE principal_uid=$1 AND action='release'",
        [departed]
      ).rows

    assert Enum.sort(released) ==
             Enum.sort([
               "email:departed@example.com",
               "email:departed.alias@example.com",
               "email:sole-departed@example.com",
               "phone:+6591234567"
             ])

    assert Repo.query!(
             "SELECT disposition FROM human_access_restrictions WHERE principal_uid=$1",
             [suspended]
           ).rows == [["suspended"]]

    assert Repo.query!(
             "SELECT disposition FROM human_access_restrictions WHERE principal_uid=$1",
             [departed]
           ).rows == [["offboarded"]]

    admins =
      Repo.query!(
        "SELECT m.principal_uid FROM principal_group_memberships m JOIN principal_groups g ON g.id=m.group_id WHERE g.name='pod_admin'"
      ).rows
      |> List.flatten()

    assert Enum.sort(admins) == Enum.sort([admin, solo, other])

    assert Repo.query!("SELECT count(*) FROM principal_groups WHERE name='pod_admin'").rows == [
             [5]
           ]

    assert Repo.query!(
             "SELECT count(*) FROM permission_grants WHERE resource_pattern='tenant_console:**'"
           ).rows == [[30]]

    assert Repo.query!(
             "SELECT allowed_identity_provider_ids FROM oidc_clients WHERE tenant_id = $1::text::uuid",
             [tenant]
           ).rows
           |> hd()
           |> hd()
           |> Enum.sort() == ["email_otp", "lark-main"]

    assert Repo.query!("SELECT provider_id FROM oidc_sessions WHERE tenant_id = $1::text::uuid", [
             tenant
           ]).rows == [["email_otp"]]

    assert Repo.query!(
             "SELECT allowed_identity_provider_ids FROM oidc_clients WHERE tenant_id = $1::text::uuid",
             [other_tenant]
           ).rows == [[["local-main"]]]

    assert Repo.query!("SELECT provider_id FROM oidc_sessions WHERE tenant_id = $1::text::uuid", [
             other_tenant
           ]).rows == [["local-main"]]

    assert Repo.query!(
             "SELECT provider_id, revoked_at FROM browser_authentications WHERE tenant_id = $1::text::uuid",
             [other_tenant]
           ).rows == [["local-main", nil]]

    assert Repo.query!(
             "SELECT revoked_at IS NOT NULL, challenge_started_at IS NOT NULL, provider_id, verified_email, amr FROM browser_authentications WHERE verified_email IS NOT NULL"
           ).rows == [[true, true, "email_otp", "admin@example.com", ["pwd"]]]

    assert Repo.query!(
             "SELECT count(*) FROM information_schema.tables WHERE table_schema=current_schema() AND table_name='human_user_local_credentials'"
           ).rows == [[0]]

    assert Repo.query!(
             "SELECT count(*) FROM information_schema.columns WHERE table_schema=current_schema() AND table_name='browser_login_transactions' AND column_name='password_ticket'"
           ).rows == [[0]]

    assert Repo.query!(
             "SELECT count(*) FROM app_configurations WHERE key LIKE 'principals.local_password.%'"
           ).rows == [[0]]
  end

  defp tenant(slug) do
    id = Ecto.UUID.generate()
    Repo.query!("INSERT INTO tenants VALUES ($1::text::uuid,$2,NULL)", [id, slug])
    id
  end

  defp person(tenant, status, email) do
    uid = Ankole.Ecto.UUIDv7.autogenerate()

    Repo.query!("INSERT INTO principals (tenant_id,uid,status) VALUES ($1::text::uuid,$2,$3)", [
      tenant,
      uid,
      status
    ])

    Repo.query!("INSERT INTO human_users VALUES ($1::text::uuid,$2,$3,'+6591234567')", [
      tenant,
      uid,
      email
    ])

    Repo.query!(
      "INSERT INTO human_user_local_credentials VALUES ($1::text::uuid,$2,'legacy-hash')",
      [tenant, uid]
    )

    uid
  end
end
