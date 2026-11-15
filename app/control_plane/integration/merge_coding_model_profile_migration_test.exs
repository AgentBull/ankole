Code.require_file(
  "../priv/repo/migrations/20261115220000_merge_coding_model_profile_into_heavy.exs",
  __DIR__
)

defmodule Ankole.MergeCodingModelProfileMigrationTest.Repo do
  use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
end

defmodule Ankole.MergeCodingModelProfileMigrationTest do
  use ExUnit.Case, async: false

  alias Ankole.MergeCodingModelProfileMigrationTest.Repo
  alias Ankole.Repo.Migrations.MergeCodingModelProfileIntoHeavy

  @moduletag timeout: 120_000
  @structure_sql Path.expand("../priv/repo/structure.sql", __DIR__)
  @version 20_261_115_220_000

  setup do
    connection =
      Ankole.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options, :types])
      |> Keyword.put(:database, "postgres")

    {:ok, admin} = Postgrex.start_link(connection)
    database = "ankole_merge_coding_#{System.system_time(:microsecond)}"
    Postgrex.query!(admin, "CREATE DATABASE #{database} TEMPLATE template0", [])
    GenServer.stop(admin)

    opts = Keyword.merge(connection, database: database, pool_size: 4, log: false)

    {:ok, _} =
      Ecto.Adapters.Postgres.structure_load(
        @structure_sql,
        Keyword.put(opts, :dump_path, @structure_sql)
      )

    start_supervised!({Repo, opts})

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(connection)
      Postgrex.query!(cleanup, "DROP DATABASE #{database} WITH (FORCE)", [])
      GenServer.stop(cleanup)
    end)

    Repo.query!(
      "INSERT INTO schema_migrations(version, inserted_at) VALUES ($1, now()) ON CONFLICT DO NOTHING",
      [@version]
    )

    :ok = Ecto.Migrator.down(Repo, @version, MergeCodingModelProfileIntoHeavy, log: false)
    :ok
  end

  test "moves coding overrides into missing heavy slots, removes coding keys, and rewrites persisted work rows" do
    Repo.query!(
      "DELETE FROM site_app_configurations WHERE key IN ('ai_gateway.model_profiles.heavy', 'ai_gateway.model_profiles.coding')"
    )

    tenant_a = Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())
    tenant_b = Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())

    for {tenant, slug} <- [{tenant_a, "tenant-a"}, {tenant_b, "tenant-b"}] do
      Repo.query!(
        "INSERT INTO tenants(id,slug,display_name,base_db_id,inserted_at,updated_at) VALUES($1,$2,$2,'migration',now(),now())",
        [tenant, slug]
      )

      Repo.query!(
        "INSERT INTO principals(tenant_id,uid,type,membership,display_name,inserted_at,updated_at) VALUES($1,$2,'human','member',$2,now(),now())",
        [tenant, "owner-#{slug}"]
      )
    end

    tenant_a_scope = "tenant:#{Ecto.UUID.load!(tenant_a)}"
    tenant_b_scope = "tenant:#{Ecto.UUID.load!(tenant_b)}"

    put_site_config("ai_gateway.model_profiles.coding", model("site-coding"))

    put_app_config(tenant_a, tenant_a_scope, "ai_gateway.model_profiles.heavy", nil)

    put_app_config(
      tenant_a,
      tenant_a_scope,
      "ai_gateway.model_profiles.coding",
      model("pod-a-coding")
    )

    put_app_config(
      tenant_b,
      tenant_b_scope,
      "ai_gateway.model_profiles.heavy",
      model("pod-b-heavy")
    )

    put_app_config(
      tenant_b,
      tenant_b_scope,
      "ai_gateway.model_profiles.coding",
      model("pod-b-coding")
    )

    put_app_config(
      tenant_a,
      "system:ankole_brain",
      "ai_gateway.model_profiles.coding",
      model("brain-coding")
    )

    insert_agent!(tenant_a, "agent-only-coding", "owner-tenant-a", %{
      "ai_agent" => %{
        "models" => %{
          "primary" => model("agent-primary"),
          "coding" => model("agent-coding")
        }
      }
    })

    insert_agent!(tenant_a, "agent-both", "owner-tenant-a", %{
      "ai_agent" => %{
        "models" => %{
          "heavy" => model("agent-heavy"),
          "coding" => model("agent-coding-discarded"),
          "kimi" => Map.put(model("agent-kimi"), "description", "Custom profile")
        }
      }
    })

    Repo.query!(
      """
      INSERT INTO background_agent_jobs(
        id, tenant_id, agent_uid, owner_session_id, workspace_owner_job_id,
        status, title, task, authorization_kind, inserted_at, updated_at
      ) VALUES
        (910001, $1, 'agent-only-coding', 'sess-1', 910001, 'succeeded', 'Default before', 'Task 1', 'service', now(), now()),
        (910002, $1, 'agent-both', 'sess-2', 910002, 'succeeded', 'Custom', 'Task 2', 'service', now(), now())
      """,
      [tenant_a]
    )

    assert Repo.query!("SELECT model_profile FROM background_agent_jobs WHERE id = 910001").rows ==
             [["coding"]]

    Repo.query!("UPDATE background_agent_jobs SET model_profile = 'kimi' WHERE id = 910002")

    Repo.query!(
      """
      INSERT INTO workflow_runs(
        id, tenant_id, agent_uid, owner_session_id, source_tool_call_id,
        title, script, concurrency, max_agent_calls, model_profile, authorization_kind,
        inserted_at, updated_at
      ) VALUES
        (920001, $1, 'agent-only-coding', 'sess-1', 'wf-1', 'Coding run', 'return 1;', 4, 16, 'coding', 'service', now(), now()),
        (920002, $1, 'agent-both', 'sess-2', 'wf-2', 'Custom run', 'return 2;', 4, 16, 'kimi', 'service', now(), now())
      """,
      [tenant_a]
    )

    Repo.query!(
      """
      INSERT INTO workflow_agent_calls(
        id, run_id, tenant_id, agent_uid, call_seq, arguments, model_profile,
        inserted_at, updated_at
      ) VALUES
        (930001, 920001, $1, 'agent-only-coding', 0, '{"prompt":"a"}'::jsonb, 'coding', now(), now()),
        (930002, 920002, $1, 'agent-both', 0, '{"prompt":"b"}'::jsonb, 'light', now(), now())
      """,
      [tenant_a]
    )

    :ok = Ecto.Migrator.up(Repo, @version, MergeCodingModelProfileIntoHeavy, log: false)

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM site_app_configurations WHERE key = 'ai_gateway.model_profiles.coding'"
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM app_configurations WHERE key = 'ai_gateway.model_profiles.coding'"
             ).rows

    assert site_config("ai_gateway.model_profiles.heavy")["model"] == "site-coding"

    assert app_config(tenant_a, tenant_a_scope, "ai_gateway.model_profiles.heavy")["model"] ==
             "pod-a-coding"

    assert app_config(tenant_b, tenant_b_scope, "ai_gateway.model_profiles.heavy")["model"] ==
             "pod-b-heavy"

    assert app_config(tenant_a, "system:ankole_brain", "ai_gateway.model_profiles.heavy")["model"] ==
             "brain-coding"

    only_coding_models = agent_models(tenant_a, "agent-only-coding")
    refute Map.has_key?(only_coding_models, "coding")
    assert only_coding_models["heavy"]["model"] == "agent-coding"
    assert only_coding_models["primary"]["model"] == "agent-primary"

    both_models = agent_models(tenant_a, "agent-both")
    refute Map.has_key?(both_models, "coding")
    assert both_models["heavy"]["model"] == "agent-heavy"
    assert both_models["kimi"]["model"] == "agent-kimi"

    Repo.query!(
      """
      INSERT INTO background_agent_jobs(
        id, tenant_id, agent_uid, owner_session_id, workspace_owner_job_id,
        status, title, task, authorization_kind, inserted_at, updated_at
      ) VALUES
        (910003, $1, 'agent-only-coding', 'sess-3', 910003, 'queued', 'Default after', 'Task 3', 'service', now(), now())
      """,
      [tenant_a]
    )

    assert Repo.query!(
             "SELECT id, model_profile FROM background_agent_jobs WHERE id IN (910001, 910002, 910003) ORDER BY id"
           ).rows == [
             [910_001, "heavy"],
             [910_002, "kimi"],
             [910_003, "heavy"]
           ]

    assert Repo.query!(
             "SELECT id, model_profile FROM workflow_runs WHERE id IN (920001, 920002) ORDER BY id"
           ).rows == [
             [920_001, "heavy"],
             [920_002, "kimi"]
           ]

    assert Repo.query!(
             "SELECT id, model_profile FROM workflow_agent_calls WHERE id IN (930001, 930002) ORDER BY id"
           ).rows == [
             [930_001, "heavy"],
             [930_002, "light"]
           ]
  end

  defp model(id), do: %{"provider_id" => "openrouter", "model" => id, "provider_options" => %{}}

  defp put_site_config(key, value) do
    Repo.query!(
      """
      INSERT INTO site_app_configurations(scope, key, value, inserted_at, updated_at)
      VALUES('global', $1, $2::jsonb, now(), now())
      """,
      [key, %{"type" => "plaintext", "value" => value}]
    )
  end

  defp put_app_config(tenant_id, scope, key, value) do
    Repo.query!(
      """
      INSERT INTO app_configurations(tenant_id, scope, key, value, inserted_at, updated_at)
      VALUES($1, $2, $3, $4::jsonb, now(), now())
      """,
      [tenant_id, scope, key, %{"type" => "plaintext", "value" => value}]
    )
  end

  defp site_config(key) do
    [[%{"value" => value}]] =
      Repo.query!(
        "SELECT value FROM site_app_configurations WHERE scope = 'global' AND key = $1",
        [
          key
        ]
      ).rows

    value
  end

  defp app_config(tenant_id, scope, key) do
    [[%{"value" => value}]] =
      Repo.query!(
        "SELECT value FROM app_configurations WHERE tenant_id = $1 AND scope = $2 AND key = $3",
        [tenant_id, scope, key]
      ).rows

    value
  end

  defp insert_agent!(tenant_id, uid, owner, options) do
    Repo.query!(
      "INSERT INTO principals(tenant_id,uid,type,display_name,status,inserted_at,updated_at) VALUES($1,$2,'agent',$2,'active',now(),now())",
      [tenant_id, uid]
    )

    Repo.query!(
      "INSERT INTO agents(tenant_id,uid,role,options,owner_principal_uid,inserted_at,updated_at) VALUES($1,$2,'tester',$3::jsonb,$4,now(),now())",
      [tenant_id, uid, options, owner]
    )
  end

  defp agent_models(tenant_id, uid) do
    [[options]] =
      Repo.query!("SELECT options FROM agents WHERE tenant_id = $1 AND uid = $2", [tenant_id, uid]).rows

    get_in(options, ["ai_agent", "models"]) || %{}
  end
end
