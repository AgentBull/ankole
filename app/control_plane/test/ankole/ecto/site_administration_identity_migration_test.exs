defmodule Ankole.Ecto.SiteAdministrationIdentityMigrationTest do
  use Ankole.DataCase, async: false

  @migration Ankole.Repo.Migrations.UseTenantIdForSiteAdministration

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261016000200_use_tenant_id_for_site_administration.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "site_administration_identity_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}")
    Repo.query!("CREATE TABLE tenants (id uuid PRIMARY KEY, slug text UNIQUE NOT NULL)")

    Repo.query!("""
    CREATE TABLE site_app_configurations (
      scope text NOT NULL,
      key text NOT NULL,
      value jsonb NOT NULL,
      inserted_at timestamp NOT NULL,
      updated_at timestamp NOT NULL,
      UNIQUE (scope, key)
    )
    """)

    :ok
  end

  test "resolves the selected slug to its exact tenant ID and retires the old key" do
    id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    insert_tenant(id, "renamed-administration")
    insert_tenant(other_id, "default")
    insert_assignment(%{"type" => "plaintext", "value" => "renamed-administration"})
    migrate()

    assert [["global", "tenants.privileged_tenant_id", envelope, ~N[2026-10-01 00:00:00.000000]]] =
             Repo.query!("SELECT scope, key, value, inserted_at FROM site_app_configurations").rows

    assert envelope == %{"type" => "plaintext", "value" => id}
  end

  test "refuses a missing assignment instead of choosing the default tenant" do
    insert_tenant(Ecto.UUID.generate(), "default")
    assert_raise Postgrex.Error, ~r/requires a valid tenants.privileged_slug/, &migrate/0
  end

  test "refuses a dangling slug instead of choosing another tenant" do
    insert_tenant(Ecto.UUID.generate(), "default")
    insert_assignment(%{"type" => "plaintext", "value" => "missing"})
    assert_raise Postgrex.Error, ~r/tenant does not exist: missing/, &migrate/0
  end

  for envelope <- [
        %{"type" => "plaintext", "value" => 123},
        %{"type" => "cipher", "value" => "default"},
        %{"type" => "plaintext", "value" => nil}
      ] do
    @envelope envelope
    test "refuses an invalid assignment #{inspect(envelope)}" do
      insert_tenant(Ecto.UUID.generate(), "default")
      insert_assignment(@envelope)
      assert_raise Postgrex.Error, ~r/requires a valid tenants.privileged_slug/, &migrate/0
    end
  end

  defp insert_tenant(id, slug) do
    Repo.query!("INSERT INTO tenants VALUES ($1, $2)", [Ecto.UUID.dump!(id), slug])
  end

  defp insert_assignment(envelope) do
    Repo.query!(
      """
      INSERT INTO site_app_configurations VALUES
        ('global', 'tenants.privileged_slug', $1, '2026-10-01', '2026-10-01')
      """,
      [envelope]
    )
  end

  defp migrate do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      20_261_016_000_200,
      @migration,
      :forward,
      :up,
      :up,
      log: false
    )
  end
end
