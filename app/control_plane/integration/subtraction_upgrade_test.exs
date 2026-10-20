defmodule Ankole.SubtractionUpgradeTest do
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ankole.Pod.{DbRecord, DbTable, Page}
  alias Ankole.Principals.Principal

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  @moduletag timeout: 180_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @migration 20_261_019_130_000
  @tenant "019a2b00-0000-7000-8000-000000000001"

  test "upgrade retains imported records and never revives an expired Job" do
    config = Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(
        :database,
        "ankole_subtraction_upgrade_#{System.unique_integer([:positive])}"
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
    uid = Ankole.Ecto.UUIDv7.autogenerate()
    now = DateTime.utc_now(:microsecond)
    author = Ankole.ActorRef.from_writer(uid, @tenant, [])

    %Principal{tenant_id: @tenant}
    |> Principal.changeset(%{uid: uid, type: :agent, display_name: "Upgrade Agent"})
    |> UpgradeRepo.insert!()

    page =
      UpgradeRepo.insert!(%Page{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        tenant_id: @tenant,
        type: :database,
        title: "Imported data",
        position: "a",
        created_by: author,
        created_at: now,
        updated_at: now
      })

    table =
      UpgradeRepo.insert!(%DbTable{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        tenant_id: @tenant,
        page_id: page.id,
        name: "Issues",
        position: "a"
      })

    record =
      UpgradeRepo.insert!(%DbRecord{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        tenant_id: @tenant,
        table_id: table.id,
        data: %{"title" => "Retained"},
        versions: %{"title" => 3},
        created_by: author,
        updated_by: author,
        created_at: now,
        updated_at: now
      })

    SQL.query!(UpgradeRepo, """
    UPDATE db_records SET external_id = 'issue-1'
    """)

    SQL.query!(UpgradeRepo, """
    INSERT INTO automation_jobs
      (tenant_id, agent_uid, owner_session_id, drive_prefix, label, status,
       expires_at, inserted_at, updated_at)
    SELECT '#{@tenant}'::uuid, '#{uid}', 'upgrade', 'automation/upgrade', status, status,
           now() - interval '1 day', now(), now()
    FROM unnest(ARRAY['active', 'expired']) AS status
    """)

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration, log: false) == [
             @migration
           ]

    assert UpgradeRepo.get_by!(DbRecord, id: record.id).data == record.data
    assert UpgradeRepo.get_by!(DbRecord, id: record.id).versions == record.versions
    assert SQL.query!(UpgradeRepo, "SELECT to_regclass('db_sync_bindings')").rows == [[nil]]

    assert SQL.query!(UpgradeRepo, "SELECT to_regclass('automation_jobs_tenant_id_id_index')").rows ==
             [[nil]]

    assert SQL.query!(UpgradeRepo, """
           SELECT label, status, cancelled_at IS NOT NULL FROM automation_jobs ORDER BY label
           """).rows == [["active", "active", false], ["expired", "cancelled", true]]

    assert SQL.query!(UpgradeRepo, """
           SELECT column_name FROM information_schema.columns
           WHERE table_schema = 'public' AND
             ((table_name = 'automation_jobs' AND column_name = 'expires_at') OR
              (table_name = 'db_records' AND column_name = 'external_id'))
           """).rows == []
  end
end
