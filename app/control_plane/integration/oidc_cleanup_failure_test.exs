defmodule Ankole.OIDCCleanupFailureIntegrationTest do
  use ExUnit.Case, async: false

  alias Ankole.OIDC.Jobs.CleanupExpiredCredentials
  alias Ankole.Repo
  alias Ankole.Tenants.Tenant

  setup do
    Ankole.DataCase.setup_sandbox(%{sandbox: false})
    :ok
  end

  test "a tenant failure still permits other tenant and site cleanup, and fails the job" do
    in_cleanup_schema(fn ->
      failed = tenant("failed")
      healthy = tenant("healthy")
      insert_code(failed, "failed")
      insert_code(healthy, "healthy")

      Repo.query!("""
      CREATE FUNCTION refuse_tenant_cleanup() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.tenant_id = '#{failed.id}'::uuid THEN
          RAISE EXCEPTION 'tenant cleanup unavailable';
        END IF;
        RETURN OLD;
      END $$;
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_tenant_cleanup BEFORE DELETE ON oidc_authorization_codes
      FOR EACH ROW EXECUTE FUNCTION refuse_tenant_cleanup()
      """)

      Repo.query!("""
      INSERT INTO browser_sessions VALUES ('#{Ecto.UUID.generate()}', now() - interval '1 day')
      """)

      assert {:error, {:tenant_failures, [{failed_id, {:exception, message}}]}} =
               CleanupExpiredCredentials.perform(%Oban.Job{})

      assert failed_id == failed.id
      assert message =~ "tenant cleanup unavailable"
      assert Repo.query!("SELECT digest FROM oidc_authorization_codes").rows == [["failed"]]
      assert Repo.query!("SELECT id FROM browser_sessions").rows == []
    end)
  end

  test "a site cleanup failure propagates after tenant cleanup" do
    in_cleanup_schema(fn ->
      tenant = tenant("healthy")
      insert_code(tenant, "expired")

      Repo.query!("""
      CREATE FUNCTION refuse_site_cleanup() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'site cleanup unavailable';
      END $$;
      """)

      Repo.query!("""
      CREATE TRIGGER refuse_site_cleanup BEFORE DELETE ON browser_sessions
      FOR EACH STATEMENT EXECUTE FUNCTION refuse_site_cleanup()
      """)

      assert_raise Postgrex.Error, ~r/site cleanup unavailable/, fn ->
        CleanupExpiredCredentials.perform(%Oban.Job{})
      end

      assert Repo.query!("SELECT digest FROM oidc_authorization_codes").rows == []
    end)
  end

  # Autocommit keeps a failed tenant statement from aborting a test-wide transaction.
  # The small schema isolates fault injection; the normal OIDC suite checks full constraints.
  defp in_cleanup_schema(fun) do
    Repo.checkout(fn ->
      schema = "oidc_cleanup_failure_#{System.unique_integer([:positive])}"
      Repo.query!("CREATE SCHEMA #{schema}")

      try do
        Repo.query!("SET search_path TO #{schema}")
        Repo.query!("CREATE TABLE tenants (LIKE public.tenants INCLUDING ALL)")

        for {table, columns} <- [
              {"oidc_authorization_codes",
               "digest text, tenant_id uuid, session_id uuid, expires_at timestamp"},
              {"oidc_refresh_tokens",
               "tenant_id uuid, session_id uuid, absolute_expires_at timestamp"},
              {"oidc_logout_requests", "tenant_id uuid, expires_at timestamp"},
              {"oidc_sessions",
               "id uuid, tenant_id uuid, browser_id uuid, expires_at timestamp, ended_at timestamp"},
              {"oidc_logout_deliveries", "tenant_id uuid, session_id uuid, status text"},
              {"browser_login_transactions", "expires_at timestamp"},
              {"browser_sessions", "id uuid, expires_at timestamp"}
            ] do
          Repo.query!("CREATE TABLE #{table} (#{columns})")
        end

        fun.()
      after
        Repo.query!("SET search_path TO public")
        Repo.query!("DROP SCHEMA #{schema} CASCADE")
      end
    end)
  end

  defp tenant(slug) do
    %Tenant{}
    |> Tenant.changeset(%{slug: slug, display_name: slug})
    |> Repo.insert!()
  end

  defp insert_code(tenant, digest) do
    Repo.query!(
      """
      INSERT INTO oidc_authorization_codes (digest, tenant_id, expires_at)
      VALUES ($1, $2, now() - interval '1 day')
      """,
      [digest, Ecto.UUID.dump!(tenant.id)]
    )
  end
end
