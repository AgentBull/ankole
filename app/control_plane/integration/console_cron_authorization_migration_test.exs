defmodule Ankole.ConsoleCronAuthorizationMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  @tenant "019a2b00-0000-7000-8000-000000000001"
  @data_tenant "019a2b00-0000-7000-8000-000000000002"
  @migration 20_261_028_030_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @moduletag timeout: 180_000

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  test "Console cron authorization changes preserve attribution, paused rules, and historical work" do
    config = Ankole.Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(
        :database,
        "ankole_console_cron_upgrade_#{System.unique_integer([:positive])}"
      )
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:log, false)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    {:ok, pid} = UpgradeRepo.start_link(config)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Supervisor.stop(pid)
      assert :ok = Ecto.Adapters.Postgres.storage_down(config)
    end)

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration - 1, log: false)
    seed_legacy_work()
    before = snapshots()

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration, log: false) == [
             @migration
           ]

    service = %{
      "authorization_kind" => "service",
      "human_uid" => nil,
      "human_access_version" => nil
    }

    expected = %{
      crons: replace_authorization(before.crons, ["console-active", "console-paused"], service),
      events:
        replace_authorization(
          before.events,
          ["console-active-pending", "console-paused-pending"],
          service
        ),
      signals: before.signals
    }

    assert snapshots() == expected
    assert expected.crons["console-paused"]["status"] == "paused"
    assert expected.crons["console-paused"]["next_fire_at"] == nil

    # Run the SQL again; a recorded migration alone would skip its statements.
    SQL.query!(UpgradeRepo, "DELETE FROM schema_migrations WHERE version = $1", [@migration])

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration, log: false) == [
             @migration
           ]

    assert snapshots() == expected

    assert_raise Ecto.MigrationError,
                 ~r/cannot restore the previous Human authorization snapshot/,
                 fn ->
                   Ecto.Migrator.run(UpgradeRepo, @migrations, :down, to: @migration, log: false)
                 end

    assert snapshots() == expected
  end

  defp replace_authorization(rows, names, authorization) do
    Map.new(rows, fn {name, row} ->
      {name, if(name in names, do: Map.merge(row, authorization), else: row)}
    end)
  end

  defp snapshots do
    Map.new([crons: "cron_schedules", events: "scheduled_events", signals: "signals"], fn
      {kind, table} ->
        key = if kind == :crons, do: "name", else: "idempotency_key"
        key = if kind == :signals, do: "source_event_id", else: key

        rows =
          SQL.query!(UpgradeRepo, "SELECT #{key}, to_jsonb(stored) FROM #{table} AS stored").rows

        {kind, Map.new(rows, fn [name, row] -> {name, row} end)}
    end)
  end

  defp seed_legacy_work do
    now = NaiveDateTime.utc_now()
    admin = Ankole.Ecto.UUIDv7.autogenerate()
    human = Ankole.Ecto.UUIDv7.autogenerate()
    agent = Ankole.Ecto.UUIDv7.autogenerate()
    admin_ref = "ankole:#{@tenant}:principal/#{admin}"
    agent_ref = "ankole:#{@data_tenant}:principal/#{agent}"
    [[base_db_id]] = SQL.query!(UpgradeRepo, "SELECT base_db_id FROM tenants LIMIT 1").rows

    UpgradeRepo.insert_all("tenants", [
      %{
        id: Ecto.UUID.dump!(@data_tenant),
        slug: "console-cron-upgrade",
        display_name: "Console cron upgrade",
        base_db_id: base_db_id,
        inserted_at: now,
        updated_at: now
      }
    ])

    for {uid, type, tenant} <- [
          {admin, "human", @tenant},
          {human, "human", @data_tenant},
          {agent, "agent", @data_tenant}
        ] do
      UpgradeRepo.insert_all("principals", [
        %{
          tenant_id: Ecto.UUID.dump!(tenant),
          uid: uid,
          type: type,
          membership: if(type == "human", do: "member"),
          status: "active",
          display_name: "Cron migration #{type}",
          access_version: 7,
          inserted_at: now,
          updated_at: now
        }
      ])

      if type == "human" do
        UpgradeRepo.insert_all("human_users", [
          %{
            tenant_id: Ecto.UUID.dump!(tenant),
            principal_uid: uid,
            inserted_at: now,
            updated_at: now
          }
        ])
      end
    end

    cases = [
      {"console-active", %{}},
      {"console-paused", %{status: "paused", next_fire_at: nil}},
      {"console-completed", %{status: "completed", next_fire_at: nil}},
      {"console-deleted", %{status: "deleted", next_fire_at: nil}},
      {"console-review",
       %{authorization_kind: "review_required", human_uid: nil, human_access_version: nil}},
      {"console-service",
       %{authorization_kind: "service", human_uid: nil, human_access_version: nil}},
      {"human-tool", %{created_by: %{"kind" => "turn", "principal_uid" => admin_ref}}},
      {"agent-tool",
       %{
         created_by: %{"kind" => "turn", "principal_uid" => agent_ref},
         authorization_kind: "service",
         human_uid: nil,
         human_access_version: nil
       }},
      {"console-reauthorized", %{human_uid: human}},
      {"console-unknown-origin",
       %{created_by: %{"kind" => "operator_api", "principal_uid" => admin}}},
      {"console-wrong-home",
       %{
         created_by: %{
           "kind" => "operator_api",
           "principal_uid" => "ankole:#{@data_tenant}:principal/#{admin}"
         }
       }}
    ]

    crons =
      Map.new(cases, fn {name, overrides} ->
        cron =
          Map.merge(
            %{
              id: Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate()),
              tenant_id: Ecto.UUID.dump!(@data_tenant),
              agent_uid: agent,
              owner_session_id: "migration-owner-#{name}",
              binding_name: "retained",
              name: name,
              status: "active",
              next_fire_at: NaiveDateTime.add(now, 3600, :second),
              last_fire_at: now,
              schedule: %{"kind" => "every", "every_ms" => 60_000},
              timezone: "Etc/UTC",
              payload: %{"task" => "Retain #{name}"},
              delivery: %{
                "targets" => [%{"binding_name" => "retained", "conversation_id" => @tenant}]
              },
              idempotency_key: name,
              created_by: %{"kind" => "operator_api", "principal_uid" => admin_ref},
              authorization_kind: "human",
              human_uid: admin,
              human_access_version: 7,
              inserted_at: now,
              updated_at: now
            },
            overrides
          )

        UpgradeRepo.insert_all("cron_schedules", [cron])
        {name, cron}
      end)

    for {name, cron} <- crons do
      legacy_event(cron, "#{name}-pending", now)
    end

    active = crons["console-active"]
    legacy_event(active, "console-active-failed", now, %{status: "failed"})

    legacy_event(active, "console-active-cancelled", now, %{
      status: "cancelled",
      cancelled_at: now
    })

    legacy_event(active, "console-active-other-human", now, %{human_uid: human})
    legacy_event(active, "console-active-other-version", now, %{human_access_version: 8})

    legacy_event(active, "human-checkback", now, %{
      kind: "check_back_later",
      cron_schedule_id: nil
    })

    signal_id = Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())

    UpgradeRepo.insert_all("signals", [
      %{
        id: signal_id,
        tenant_id: active.tenant_id,
        agent_uid: agent,
        session_id: "cron:#{Ecto.UUID.load!(active.id)}",
        producer: "kernel",
        source: "urn:ankole:cron-migration",
        source_event_id: "retained-fired-signal",
        type: "cron.fire",
        status: "queued",
        queue_sequence: 1,
        occurred_at: now,
        available_at: now,
        data: %{"task" => "Retain history"},
        authorization_kind: "human",
        human_uid: admin,
        human_access_version: 7,
        inserted_at: now,
        updated_at: now
      }
    ])

    legacy_event(active, "console-active-fired", now, %{
      status: "fired",
      signal_id: signal_id,
      fired_at: now
    })
  end

  defp legacy_event(cron, name, now, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          tenant_id: cron.tenant_id,
          agent_uid: cron.agent_uid,
          session_id: "cron:#{Ecto.UUID.load!(cron.id)}",
          cron_schedule_id: cron.id,
          kind: "cron_fire",
          status: "scheduled",
          binding_name: "retained",
          due_at: now,
          timezone: "Etc/UTC",
          requested_at: now,
          idempotency_key: name,
          source_provenance: %{"kind" => "operator_api"},
          wake_payload: %{"trigger" => "manual", "payload" => %{"task" => "Retain #{name}"}},
          authorization_kind: cron.authorization_kind,
          human_uid: cron.human_uid,
          human_access_version: cron.human_access_version,
          inserted_at: now,
          updated_at: now
        },
        overrides
      )

    UpgradeRepo.insert_all("scheduled_events", [attrs])
  end
end
