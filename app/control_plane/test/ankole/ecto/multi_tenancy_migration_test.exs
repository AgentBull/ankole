defmodule Ankole.Ecto.MultiTenancyMigrationTest do
  use Ankole.DataCase, async: false
  @migration Ankole.Repo.Migrations.AddMultiTenancy
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand("../../../priv/repo/migrations/20261009120000_add_multi_tenancy.exs", __DIR__)
    )
  end

  setup do
    schema = "multi_tenancy_migration_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")
    :ok
  end

  test "old rows gain tenant ownership without tuple rewrites and new rows require explicit ownership" do
    Repo.query!("CREATE TABLE tenants (id uuid PRIMARY KEY)")
    Repo.query!("INSERT INTO tenants VALUES ('019a2b00-0000-7000-8000-000000000001')")
    Repo.query!("CREATE TABLE owned (value text)")
    Repo.query!("INSERT INTO owned VALUES ('durable fact')")
    [[old_ctid]] = Repo.query!("SELECT ctid::text FROM owned").rows
    Enum.each(@migration.tenant_column_sqls("owned"), &Repo.query!/1)

    assert [["durable fact", "019a2b00-0000-7000-8000-000000000001", ^old_ctid]] =
             Repo.query!("SELECT value, tenant_id::text, ctid::text FROM owned").rows

    assert [[true, true]] =
             Repo.query!(
               "SELECT attnotnull, atthasmissing FROM pg_attribute WHERE attrelid = 'owned'::regclass AND attname = 'tenant_id'"
             ).rows

    assert [[0]] =
             Repo.query!("SELECT count(*) FROM pg_attrdef WHERE adrelid = 'owned'::regclass").rows

    assert_raise Postgrex.Error, ~r/null value/, fn ->
      Repo.query!("INSERT INTO owned VALUES ('missing owner')")
    end
  end

  test "Agent configuration gains tenant ownership without losing its encryption binding" do
    scope = "agent:old-agent"
    key = "agent.secret"
    assert {:ok, ciphertext} = Ankole.AppConfigure.Crypto.seal("operator value", scope, key)
    Repo.query!("CREATE TABLE tenants (id uuid PRIMARY KEY)")
    Repo.query!("INSERT INTO tenants VALUES ('019a2b00-0000-7000-8000-000000000001')")

    Repo.query!(
      "CREATE TABLE app_configurations (scope text, key text, value jsonb, CONSTRAINT app_configurations_scope_check CHECK (scope = 'global' OR scope ~ '^agent:.+$'))"
    )

    envelope = %{"type" => "cipher", "value" => ciphertext}
    Repo.query!("INSERT INTO app_configurations VALUES ($1, $2, $3)", [scope, key, envelope])

    Repo.query!("INSERT INTO app_configurations VALUES ($1, $2, $3)", [
      scope,
      "security.ssrf_filter",
      %{"type" => "plaintext", "value" => false}
    ])

    Enum.each(@migration.site_row_ownership_sqls("app_configurations"), &Repo.query!/1)
    Repo.query!(@migration.plaintext_configuration_sql())

    assert [[^scope, ^key, ^envelope, "019a2b00-0000-7000-8000-000000000001"]] =
             Repo.query!(
               "SELECT scope, key, value, tenant_id::text FROM app_configurations WHERE key = $1",
               [key]
             ).rows

    assert [
             [
               ^scope,
               %{"type" => "plaintext", "value" => false},
               "019a2b00-0000-7000-8000-000000000001"
             ]
           ] =
             Repo.query!(
               "SELECT scope, value, tenant_id::text FROM app_configurations WHERE key = 'security.ssrf_filter'"
             ).rows

    assert {:ok, "operator value"} = Ankole.AppConfigure.Crypto.unseal(ciphertext, scope, key)
  end

  test "admin scope migration updates live bodies and snapshots while preserving literal text" do
    for {table, column} <- [
          {"brain_sources", "default_audience_scope"},
          {"brain_chunks", "audience_scope"},
          {"brain_claims", "audience_scope"},
          {"brain_timelines", "audience_scope"}
        ] do
      Repo.query!("CREATE TABLE #{table} (#{column} text)")
      Repo.query!("INSERT INTO #{table} VALUES ('group:admin'), ('group:admins')")
    end

    body = """
    Literal scope="group:admin".
    {% audience scope="group:admin" %}First{% /audience %}
    {%  audience\tscope="group:admin"\t%}Second{% /audience %}
    {% audience scope="group:admins" %}Other{% /audience %}
    """

    expected =
      String.replace(body, "scope=\"group:admin\" %}", "scope=\"group:siteadmin\" %}")
      |> String.replace("scope=\"group:admin\"\t%}", "scope=\"group:siteadmin\"\t%}")

    for table <- ~w(brain_objects brain_object_versions) do
      Repo.query!("CREATE TABLE #{table} (body text)")
      Repo.query!("INSERT INTO #{table} VALUES ($1)", [body])
    end

    Enum.each(@migration.admin_audience_sqls(), &Repo.query!/1)

    for table <- ~w(brain_objects brain_object_versions),
        do: assert([[expected]] == Repo.query!("SELECT body FROM #{table}").rows)

    assert Enum.sort(Repo.query!("SELECT audience_scope FROM brain_chunks").rows) ==
             Enum.sort([["group:siteadmin"], ["group:admins"]])
  end
end
