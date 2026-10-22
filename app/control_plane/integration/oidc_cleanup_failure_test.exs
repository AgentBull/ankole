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
      INSERT INTO browser_sessions (id, expires_at, inserted_at, updated_at)
      VALUES ('#{Ecto.UUID.generate()}', now() - interval '1 day', now(), now())
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

      error =
        assert_raise Ash.Error.Unknown, ~r/site cleanup unavailable/, fn ->
          CleanupExpiredCredentials.perform(%Oban.Job{})
        end

      assert [%Ash.Error.Unknown.UnknownError{error: message}] = error.errors

      assert message ==
               "** (Postgrex.Error) ERROR P0001 (raise_exception) site cleanup unavailable"

      assert Repo.query!("SELECT digest FROM oidc_authorization_codes").rows == []
    end)
  end

  # Autocommit keeps a failed tenant statement from aborting a test-wide transaction.
  # Copy the current tables to isolate fault injection without a second protocol schema.
  defp in_cleanup_schema(fun) do
    Repo.checkout(fn ->
      schema = "oidc_cleanup_failure_#{System.unique_integer([:positive])}"
      Repo.query!("CREATE SCHEMA #{schema}")

      try do
        Repo.query!("SET search_path TO #{schema}")

        for table <- ~w(
              tenants
              oidc_authorization_codes
              oidc_refresh_token_families
              oidc_refresh_tokens
              oidc_logout_requests
              oidc_sessions
              oidc_logout_deliveries
              browser_login_transactions
              browser_sessions
            ) do
          Repo.query!("CREATE TABLE #{table} (LIKE public.#{table} INCLUDING ALL)")
        end

        fun.()
      after
        Repo.query!("SET search_path TO public")
        Repo.query!("DROP SCHEMA #{schema} CASCADE")
      end
    end)
  end

  defp tenant(slug) do
    {:ok, tenant} =
      Repo.transact(fn _repo ->
        Ankole.Ash.create(Tenant, :create_in_tx, %{slug: slug, display_name: slug})
      end)

    tenant
  end

  defp insert_code(tenant, digest) do
    Repo.query!(
      """
      INSERT INTO oidc_authorization_codes
        (digest, tenant_id, client_id, principal_uid, redirect_uri, scope,
         code_challenge, session_id, expires_at, inserted_at)
      VALUES ($1, $2, $3, $4, 'https://cleanup.example.test/callback', 'openid',
              $5, $6, now() - interval '1 day', now())
      """,
      [
        digest,
        Ecto.UUID.dump!(tenant.id),
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        "cleanup-test-principal",
        String.duplicate("a", 43),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )
  end
end
