defmodule Ankole.PodModelProfileMigrationTest.Repo do
  use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
end

defmodule Ankole.PodModelProfileMigrationTest do
  use ExUnit.Case, async: false

  alias Ankole.PodModelProfileMigrationTest.Repo

  @moduletag timeout: 120_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @previous 20_261_030_120_000
  @version 20_261_031_120_000
  @slots ~w(primary light heavy coding vision_fallback web_search web_fetch image_generate)

  setup do
    connection =
      Ankole.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :ssl, :socket_options, :types])
      |> Keyword.put(:database, "postgres")

    {:ok, admin} = Postgrex.start_link(connection)
    database = "ankole_pod_profiles_#{System.system_time(:microsecond)}"
    Postgrex.query!(admin, "CREATE DATABASE #{database} TEMPLATE template0", [])
    GenServer.stop(admin)
    opts = Keyword.merge(connection, database: database, pool_size: 4, log: false)
    start_supervised!({Repo, opts})

    on_exit(fn ->
      {:ok, cleanup} = Postgrex.start_link(connection)
      Postgrex.query!(cleanup, "DROP DATABASE #{database} WITH (FORCE)", [])
      GenServer.stop(cleanup)
    end)

    Ecto.Migrator.run(Repo, @migrations, :up, to: @previous, log: false)
    :ok
  end

  test "legacy Agents adopt Pod defaults and deduplication preserves the merged configuration" do
    fixture = seed!()
    migrate!()

    for tenant <- [fixture.a, fixture.b, fixture.c] do
      assert [[1]] =
               Repo.query!(
                 "SELECT count(*) FROM principals WHERE tenant_id = $1 AND type = 'system' AND uid = 'system'",
                 [
                   tenant
                 ]
               ).rows
    end

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM app_configurations WHERE key IN ('brain.maintainer_agent_uid','brain.rerank_model')"
             ).rows

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM site_app_configurations WHERE key IN ('brain.maintainer_agent_uid','brain.rerank_model')"
             ).rows

    assert profile_value(fixture.a, "primary")["model"] == "global-primary"
    assert profile_value(fixture.b, "primary")["model"] == "tenant-primary"
    assert profile_value(fixture.c, "primary")["model"] == "first-primary"
    assert profile_value(fixture.a, "rerank")["model"] == "global-rerank"

    assert [[0]] =
             Repo.query!(
               "SELECT count(*) FROM app_configurations WHERE key = 'ai_gateway.model_profiles.rerank' AND jsonb_typeof(value -> 'value') <> 'object'"
             ).rows

    for {tenant, agent_options} <- [
          {fixture.a, fixture.global_agent_options},
          {fixture.b, fixture.tenant_agent_options},
          {fixture.c, fixture.first_agent_options},
          {fixture.c, fixture.second_agent_options}
        ] do
      for agent <- agent_options do
        assert_deduplication_equivalence(tenant, agent)
      end
    end

    # Missing Agent slots uniformly inherit the newly seeded Pod configuration.
    refute Map.has_key?(fixture.peer_options["ai_agent"]["models"], "web_fetch")

    peer =
      Map.merge(
        Map.new(@slots, &{&1, inherited_value(fixture.a, &1)}),
        final_models(fixture.a, fixture.peer_uid)
      )

    assert peer["primary"]["model"] == "peer-primary"
    assert peer["web_fetch"]["model"] == "global-fetch"
    assert peer["light"]["model"] == "global-light"
    assert_deduplication_equivalence(fixture.a, {fixture.peer_uid, fixture.peer_options})

    second_models = final_models(fixture.c, fixture.second_uid)

    assert second_models["custom"]["model"] == "custom-llm"
    refute Map.has_key?(second_models, "primary")
    assert final_hosted(fixture.c, fixture.second_uid) == %{"image_generate" => false}

    constraint =
      Repo.query!(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'ai_gateway_usage_records_origin_check'"
      ).rows
      |> List.first()
      |> List.first()

    for origin <- ~w(agent codex applet brain oidc_human compaction) do
      assert constraint =~ "'#{origin}'"
    end

    assert_raise Ecto.MigrationError, ~r/irreversible.*pre-upgrade database backup/, fn ->
      Ecto.Migrator.run(Repo, @migrations, :down, step: 1, log: false)
    end
  end

  test "legacy system names and their audit attribution become the generic system identity" do
    fixture = seed!()

    for {tenant, uid} <- [{fixture.a, "legacy-brain"}, {fixture.b, Ecto.UUID.generate()}] do
      Repo.query!(
        "INSERT INTO principals(tenant_id,uid,type,display_name,inserted_at,updated_at) VALUES($1,$2,'system','System',now(),now())",
        [tenant, uid]
      )

      Repo.query!(
        "UPDATE agents SET created_by='ankole:' || tenant_id::text || ':principal/' || $2 WHERE tenant_id=$1",
        [tenant, uid]
      )
    end

    migrate!()

    for tenant <- [fixture.a, fixture.b, fixture.c] do
      assert [["system"]] =
               Repo.query!("SELECT uid FROM principals WHERE tenant_id=$1 AND type='system'", [
                 tenant
               ]).rows
    end

    for tenant <- [fixture.a, fixture.b] do
      assert [[true]] =
               Repo.query!(
                 "SELECT bool_and(created_by='ankole:' || tenant_id::text || ':principal/system') FROM agents WHERE tenant_id=$1",
                 [tenant]
               ).rows
    end

    assert [["system"]] =
             Repo.query!(
               "SELECT p.uid FROM principals p JOIN tenants t ON t.id=p.tenant_id WHERE t.slug='default' AND p.type='system'"
             ).rows
  end

  test "migration keeps same-named Agents in different tenants independent" do
    Ecto.Migrator.run(Repo, @migrations, :up, to: 20_261_031_110_000, log: false)
    fixture = seed!()

    for {tenant, [{uid, _options}]} <- [
          {fixture.a, fixture.global_agent_options},
          {fixture.b, fixture.tenant_agent_options}
        ] do
      Repo.query!("UPDATE principals SET uid = 'shared' WHERE tenant_id = $1 AND uid = $2", [
        tenant,
        uid
      ])
    end

    for table <- ["site_app_configurations", "app_configurations"] do
      Repo.query!(
        "UPDATE #{table} SET value = jsonb_set(value, '{value}', '\"shared\"'::jsonb) WHERE key = 'brain.maintainer_agent_uid'"
      )
    end

    migrate!()

    assert profile_value(fixture.a, "primary")["model"] == "global-primary"
    assert profile_value(fixture.b, "primary")["model"] == "tenant-primary"

    for {tenant, [{_uid, original}]} <- [
          {fixture.a, fixture.global_agent_options},
          {fixture.b, fixture.tenant_agent_options}
        ] do
      assert_deduplication_equivalence(tenant, {"shared", original})
    end
  end

  defp assert_deduplication_equivalence(tenant, {uid, original_options}) do
    original_models = get_in(original_options, ["ai_agent", "models"]) || %{}
    final = final_models(tenant, uid)

    expected_direct =
      Map.new(@slots, fn slot ->
        {slot, original_models[slot] || inherited_value(tenant, slot)}
      end)

    actual_direct =
      Map.new(@slots, fn slot -> {slot, final[slot] || inherited_value(tenant, slot)} end)

    for slot <- @slots do
      expected = effective_value(expected_direct, slot)
      actual = effective_value(actual_direct, slot)

      assert actual == expected,
             "#{uid} changed effective #{slot}: #{inspect({actual, expected})}"
    end

    original_hosted = get_in(original_options, ["ai_agent", "provider_hosted"]) || %{}

    for capability <- ~w(web_search image_generate) do
      expected = Map.get(original_hosted, capability, true)
      assert Map.get(final_hosted(tenant, uid), capability, true) == expected
    end
  end

  defp effective_value(models, "coding"),
    do: models["coding"] || models["heavy"] || models["primary"]

  defp effective_value(models, "light"), do: models["light"] || models["primary"]
  defp effective_value(models, slot), do: models[slot]

  defp inherited_value(tenant, slot) do
    profile_value(tenant, slot)
  end

  defp profile_value(tenant, slot) do
    key = "ai_gateway.model_profiles.#{slot}"

    case Repo.query!(
           "SELECT value -> 'value' FROM app_configurations WHERE tenant_id = $1 AND key = $2",
           [tenant, key]
         ).rows do
      [[value]] -> value
      [] -> global_profile_value(key)
    end
  end

  defp global_profile_value(key) do
    case Repo.query!("SELECT value -> 'value' FROM site_app_configurations WHERE key = $1", [key]).rows do
      [[value]] -> value
      [] -> nil
    end
  end

  defp final_models(tenant, uid) do
    options =
      Repo.query!("SELECT options FROM agents WHERE tenant_id = $1 AND uid = $2", [tenant, uid]).rows
      |> List.first()
      |> List.first()

    get_in(options, ["ai_agent", "models"]) || %{}
  end

  defp final_hosted(tenant, uid) do
    options =
      Repo.query!("SELECT options FROM agents WHERE tenant_id = $1 AND uid = $2", [tenant, uid]).rows
      |> List.first()
      |> List.first()

    get_in(options, ["ai_agent", "provider_hosted"]) || %{}
  end

  defp migrate! do
    Ecto.Migrator.run(Repo, @migrations, :up, to: @version, log: false)
  end

  defp seed! do
    [a, b, c] = for _ <- 1..3, do: Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())
    global_uid = "agent-global"
    peer_uid = "agent-peer"
    tenant_uid = "agent-tenant"
    first_uid = "agent-first"
    second_uid = "agent-second"

    for {tenant, slug} <- [{a, "tenant-a"}, {b, "tenant-b"}, {c, "tenant-c"}] do
      Repo.query!(
        "INSERT INTO tenants(id,slug,display_name,base_db_id,inserted_at,updated_at) VALUES($1,$2,$2,'migration',now(),now())",
        [tenant, slug]
      )

      Repo.query!(
        "INSERT INTO principals(tenant_id,uid,type,membership,display_name,inserted_at,updated_at) VALUES($1,$2,'human','member',$2,now(),now())",
        [tenant, "owner-#{slug}"]
      )
    end

    global_options =
      options(%{
        "primary" => model("global-primary"),
        "light" => model("global-light"),
        "heavy" => model("global-heavy"),
        "web_fetch" => model("global-fetch")
      })

    peer_options = options(%{"primary" => model("peer-primary")})
    tenant_options = options(%{"primary" => model("tenant-primary")})
    first_options = options(%{"primary" => model("first-primary")})

    second_options =
      options(%{
        "primary" => model("first-primary"),
        "custom" => model("custom-llm")
      })

    second_options =
      put_in(second_options, ["ai_agent", "provider_hosted"], %{
        "web_search" => true,
        "image_generate" => false
      })

    for {tenant, uid, inserted_at, opts, owner} <- [
          {a, global_uid, ~N[2026-01-01 00:00:00], global_options, "owner-tenant-a"},
          {a, peer_uid, ~N[2026-01-02 00:00:00], peer_options, "owner-tenant-a"},
          {b, tenant_uid, ~N[2026-01-02 00:00:00], tenant_options, "owner-tenant-b"},
          {c, first_uid, ~N[2026-01-01 00:00:00], first_options, "owner-tenant-c"},
          {c, second_uid, ~N[2026-01-03 00:00:00], second_options, "owner-tenant-c"}
        ] do
      Repo.query!(
        "INSERT INTO principals(tenant_id,uid,type,display_name,status,inserted_at,updated_at) VALUES($1,$2,'agent',$2,'active',$3::timestamp,now())",
        [tenant, uid, inserted_at]
      )

      Repo.query!(
        "INSERT INTO agents(tenant_id,uid,handle,role,options,owner_principal_uid,inserted_at,updated_at) VALUES($1,$2,$2,'tester',$3::jsonb,$4,now(),now())",
        [tenant, uid, opts, owner]
      )
    end

    put_site_config("brain.maintainer_agent_uid", global_uid)
    put_tenant_config(b, "brain.maintainer_agent_uid", tenant_uid)
    put_site_config("brain.rerank_model", model("global-rerank"))
    put_tenant_config(a, "brain.rerank_model", nil)

    %{
      a: a,
      b: b,
      c: c,
      global_agent_options: [{global_uid, global_options}],
      tenant_agent_options: [{tenant_uid, tenant_options}],
      first_agent_options: [{first_uid, first_options}],
      second_agent_options: [{second_uid, second_options}],
      second_uid: second_uid,
      peer_uid: peer_uid,
      peer_options: peer_options
    }
  end

  defp options(models) do
    %{"ai_agent" => %{"models" => models, "provider_hosted" => %{"web_search" => true}}}
  end

  defp model(model), do: %{"provider_id" => "legacy-provider", "model" => model}

  defp put_site_config(key, value) do
    Repo.query!(
      "INSERT INTO site_app_configurations(scope,key,value,inserted_at,updated_at) VALUES('global',$1,$2::jsonb,now(),now())",
      [key, %{"type" => "plaintext", "value" => value}]
    )
  end

  defp put_tenant_config(tenant, key, value) do
    Repo.query!(
      "INSERT INTO app_configurations(tenant_id,scope,key,value,inserted_at,updated_at) VALUES($1::uuid,'tenant:' || $1::text,$2,$3::jsonb,now(),now())",
      [tenant, key, %{"type" => "plaintext", "value" => value}]
    )
  end
end
