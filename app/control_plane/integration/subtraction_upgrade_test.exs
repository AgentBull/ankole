defmodule Ankole.SubtractionUpgradeTest do
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ankole.Pod.DbRecord

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  @moduletag timeout: 180_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @migration 20_261_019_130_000
  @brain_split 20_261_020_103_000
  @brain_tags 20_261_020_103_100
  @tenant "019a2b00-0000-7000-8000-000000000001"

  test "upgrade retains imported records and never revives an expired Job" do
    start_upgrade_repo!()

    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration - 1, log: false)
    uid = Ankole.Ecto.UUIDv7.autogenerate()
    now = DateTime.utc_now(:microsecond)
    author = Ankole.ActorRef.from_writer(uid, @tenant, [])

    SQL.query!(
      UpgradeRepo,
      """
      INSERT INTO principals
        (uid, tenant_id, type, status, display_name, access_version, inserted_at, updated_at)
      VALUES ($1, $2, 'agent', 'active', 'Upgrade Agent', 1, $3, $3)
      """,
      [uid, Ecto.UUID.dump!(@tenant), now]
    )

    page = %{id: Ankole.Ecto.UUIDv7.autogenerate()}

    {1, nil} =
      UpgradeRepo.insert_all("pages", [
        %{
          id: Ecto.UUID.dump!(page.id),
          tenant_id: Ecto.UUID.dump!(@tenant),
          type: "database",
          title: "Imported data",
          position: "a",
          created_by: to_string(author),
          created_at: now,
          updated_at: now
        }
      ])

    table = %{id: Ankole.Ecto.UUIDv7.autogenerate()}

    {1, nil} =
      UpgradeRepo.insert_all("db_tables", [
        %{
          id: Ecto.UUID.dump!(table.id),
          tenant_id: Ecto.UUID.dump!(@tenant),
          page_id: Ecto.UUID.dump!(page.id),
          name: "Issues",
          position: "a"
        }
      ])

    record = %{
      id: Ankole.Ecto.UUIDv7.autogenerate(),
      data: %{"title" => "Retained"},
      versions: %{"title" => 3}
    }

    {1, nil} =
      UpgradeRepo.insert_all("db_records", [
        %{
          id: Ecto.UUID.dump!(record.id),
          tenant_id: Ecto.UUID.dump!(@tenant),
          table_id: Ecto.UUID.dump!(table.id),
          data: record.data,
          versions: record.versions,
          created_by: to_string(author),
          updated_by: to_string(author),
          created_at: now,
          updated_at: now
        }
      ])

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

  test "Brain upgrade keeps timeline progress and tag content baselines" do
    pid = start_upgrade_repo!()
    Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @brain_split - 1, log: false)

    created_at = ~N[2026-10-18 10:00:00.000000]
    extracted_at = ~N[2026-10-19 10:00:00.000000]
    tagged_id = Ankole.Ecto.UUIDv7.autogenerate()
    untagged_id = Ankole.Ecto.UUIDv7.autogenerate()
    version_id = Ankole.Ecto.UUIDv7.autogenerate()
    title = "Upgrade memory"
    body = "Persisted memory body."
    meta = %{"source" => "upgrade"}

    canonical_meta =
      meta
      |> Enum.sort_by(fn {key, _} -> to_string(key) end)
      |> inspect(limit: :infinity, printable_limit: :infinity)

    old_hash =
      Ankole.Kernel.xxh3_128_hex("#{title}\u0000#{body}\u0000#{canonical_meta}\u0000\u0000")

    for {id, slug} <- [{tagged_id, "notes/tagged-upgrade"}, {untagged_id, "notes/plain-upgrade"}] do
      SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO brain_objects
          (id, tenant_id, slug, type, title, body, meta, content_hash,
           created_at, updated_at, links_extracted_at)
        VALUES ($1::text::uuid, $2::text::uuid, $3, 'note', $4, $5, $6, $7, $8, $8, $9)
        """,
        [id, @tenant, slug, title, body, meta, old_hash, created_at, extracted_at]
      )
    end

    for tag <- ["研究", "AI"] do
      SQL.query!(
        UpgradeRepo,
        """
        INSERT INTO brain_tags (id, tenant_id, object_slug, tag, created_at)
        VALUES ($1::text::uuid, $2::text::uuid, 'notes/tagged-upgrade', $3, $4)
        """,
        [Ankole.Ecto.UUIDv7.autogenerate(), @tenant, tag, created_at]
      )
    end

    SQL.query!(
      UpgradeRepo,
      """
      INSERT INTO brain_object_versions (id, tenant_id, object_id, body, meta, snapshot_at)
      VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'Historical body', $4, $5)
      """,
      [version_id, @tenant, tagged_id, %{"historical" => true}, created_at]
    )

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @brain_tags, log: false) ==
             [@brain_split, @brain_tags]

    rows =
      SQL.query!(UpgradeRepo, """
      SELECT slug, title, body, meta, links_extracted_at, timelines_extracted_at, content_hash
      FROM brain_objects WHERE slug IN ('notes/tagged-upgrade', 'notes/plain-upgrade')
      ORDER BY slug
      """).rows

    assert [
             ["notes/plain-upgrade", ^title, ^body, ^meta, nil, ^extracted_at, ^old_hash],
             ["notes/tagged-upgrade", ^title, ^body, ^meta, nil, ^extracted_at, tagged_hash]
           ] = rows

    refute tagged_hash == old_hash

    assert SQL.query!(UpgradeRepo, """
           SELECT tag FROM brain_tags WHERE object_slug = 'notes/tagged-upgrade' ORDER BY tag COLLATE "C"
           """).rows == [["AI"], ["研究"]]

    assert SQL.query!(
             UpgradeRepo,
             """
             SELECT body, meta, tags FROM brain_object_versions WHERE id = $1::text::uuid
             """,
             [version_id]
           ).rows == [["Historical body", %{"historical" => true}, []]]

    previous = Repo.get_dynamic_repo()

    try do
      Repo.put_dynamic_repo(pid)

      Repo.with_tenant(@tenant, fn ->
        # A no-content-change save computes the runtime baseline from the real
        # stored tags. It must agree with the frozen migration encoding.
        assert {:ok, object} =
                 Ankole.Brain.Objects.update_object(
                   "notes/tagged-upgrade",
                   %{expected_content_hash: tagged_hash},
                   :system
                 )

        assert object.content_hash == tagged_hash

        assert SQL.query!(
                 UpgradeRepo,
                 """
                 SELECT tags FROM brain_object_versions
                 WHERE object_id = $1::text::uuid AND id <> $2::text::uuid
                 """,
                 [tagged_id, version_id]
               ).rows == [[["AI", "研究"]]]
      end)
    after
      Repo.put_dynamic_repo(previous)
    end

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @brain_tags, log: false) == []
  end

  defp start_upgrade_repo! do
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

    pid
  end
end
