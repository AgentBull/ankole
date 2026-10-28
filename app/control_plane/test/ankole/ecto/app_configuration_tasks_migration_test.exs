defmodule Ankole.Ecto.AppConfigurationTasksMigrationTest do
  use Ankole.DataCase, async: false

  @migration Ankole.Repo.Migrations.GovernAppConfigurationTasks
  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../../../priv/repo/migrations/20261028120000_govern_app_configuration_tasks.exs",
        __DIR__
      )
    )
  end

  setup do
    schema = "configure_tasks_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{schema}")
    Repo.query!("SET LOCAL search_path TO #{schema}, public")

    for {table, tenant} <- [
          {"site_app_configurations", ""},
          {"app_configurations", "tenant_id uuid NOT NULL, "}
        ] do
      Repo.query!(
        "CREATE TABLE #{table} (#{tenant}scope text NOT NULL, key text NOT NULL, value jsonb NOT NULL, inserted_at timestamp NOT NULL, updated_at timestamp NOT NULL)"
      )
    end

    :ok
  end

  test "migration preserves site, tenant, and Agent values while splitting retention and combining OTP limits",
       %{tenant: tenant} do
    legacy = [
      {"agent_computer.worker.ready_timeout", "agent_workers.ready_timeout_seconds", 120},
      {"worker.rendered_fetch_idle_ttl_ms", "agent_workers.rendered_fetch_idle_ttl_ms",
       1_800_000},
      {"agent_computer.background_agent_job.max_running_per_agent",
       "background_agent_jobs.max_running_per_agent", 3}
    ]

    forgetting = %{
      "event_halflife_days" => 7,
      "preference_halflife_days" => 90,
      "commitment_halflife_days" => 90,
      "belief_halflife_days" => 365,
      "fact_halflife_days" => 365,
      "purge_soft_delete_ttl_hours" => 36.5
    }

    for scope <- ["global", "tenant:" <> tenant.id, "agent:existing-agent"] do
      for {old, _, value} <- legacy, do: put(scope, old, value, tenant.id)
      put(scope, "brain.forgetting", forgetting, tenant.id)
    end

    put("global", "authn.email.send_window_seconds", 120)
    put("global", "authn.email.send_email_limit", 5)
    put("global", "authn.email.failure_source_limit", 50)
    # The ciphertext stays byte-for-byte in the owning key; the migration only adds enablement.
    secret = %{"type" => "cipher", "value" => "opaque-existing-secret"}
    put("global", "saas.turnstile.site_key", "site-key")
    put_envelope("global", "saas.turnstile.secret_key", secret)
    migrate()

    for scope <- ["global", "tenant:" <> tenant.id, "agent:existing-agent"] do
      for {old, new, value} <- legacy do
        assert rows(scope, old) == []

        assert [[%{"type" => "plaintext", "value" => ^value}, ~N[2026-10-01 00:00:00.000000]]] =
                 rows(scope, new)
      end

      assert [[%{"value" => retained}, _]] = rows(scope, "brain.forgetting")
      assert retained == Map.delete(forgetting, "purge_soft_delete_ttl_hours")
      assert [[%{"value" => 36.5}, _]] = rows(scope, "brain.soft_delete_retention_hours")
    end

    assert [
             [
               %{
                 "value" => %{
                   "window_seconds" => 120,
                   "per_email" => 5,
                   "per_source" => 20,
                   "per_channel" => 100
                 }
               },
               _
             ]
           ] = rows("global", "authn.email.send_limits")

    assert [[%{"value" => %{"window_seconds" => 600, "per_email" => 10, "per_source" => 50}}, _]] =
             rows("global", "authn.email.failure_limits")

    assert rows("global", "authn.email.send_email_limit") == []
    assert [[%{"value" => true}, _]] = rows("global", "saas.turnstile.enabled")

    assert [[^secret, ~N[2026-10-01 00:00:00.000000]]] =
             rows("global", "saas.turnstile.secret_key")
  end

  test "an incomplete Turnstile pair stays disabled without inventing OTP overrides" do
    put("global", "saas.turnstile.site_key", "site-key")
    migrate()
    assert [[%{"value" => false}, _]] = rows("global", "saas.turnstile.enabled")
    assert rows("global", "authn.email.send_limits") == []
    assert rows("global", "authn.email.failure_limits") == []
  end

  defp put(scope, key, value, tenant_id \\ nil),
    do: put_envelope(scope, key, %{"type" => "plaintext", "value" => value}, tenant_id)

  defp put_envelope(scope, key, envelope, tenant_id \\ nil) do
    if scope == "global" do
      Repo.query!(
        "INSERT INTO site_app_configurations VALUES ($1, $2, $3, '2026-10-01', '2026-10-01')",
        [scope, key, envelope]
      )
    else
      Repo.query!(
        "INSERT INTO app_configurations VALUES ($1::text::uuid, $2, $3, $4, '2026-10-01', '2026-10-01')",
        [tenant_id, scope, key, envelope]
      )
    end
  end

  defp rows(scope, key) do
    table = if scope == "global", do: "site_app_configurations", else: "app_configurations"

    Repo.query!("SELECT value, inserted_at FROM #{table} WHERE scope = $1 AND key = $2", [
      scope,
      key
    ]).rows
  end

  defp migrate do
    assert {:ok, :done} =
             Repo.transact(fn _ ->
               Ecto.Migration.Runner.run(
                 Repo,
                 Repo.config(),
                 20_261_028_120_000,
                 @migration,
                 :forward,
                 :up,
                 :up,
                 log: false
               )

               {:ok, :done}
             end)
  end
end
