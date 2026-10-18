defmodule Ankole.PublishedVersionUpgradeIntegrationTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  @moduletag :external
  @moduletag timeout: 180_000
  @root Path.expand("../../..", __DIR__)
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @default_tenant "019a2b00-0000-7000-8000-000000000001"

  # One origin for each distinct published migration tree from v0.70.0 onward.
  @origins ~w(v0.70.0 v0.72.0 v0.74.0 v1.0.0-rc.2 v1.0.0-rc.3 v1.0.0-rc.6
    v1.0.0-rc.7 v1.0.3-rc.2 v1.1.0-rc.1 v1.2.0-rc.1 v1.5.1-rc.1
    v2.0.0-alpha.1 v2.0.0-alpha.2 v2.0.0-alpha.5)

  for origin <- @origins do
    @origin origin
    test "#{origin} preserves a Principal through schema upgrade and a repeated migration" do
      directory = Path.join(System.tmp_dir!(), "ankole-upgrade-#{Ecto.UUID.generate()}")
      File.mkdir_p!(directory)
      on_exit(fn -> File.rm_rf!(directory) end)
      archive = Path.join(directory, "origin.tar")

      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["archive", "-o", archive, @origin, "app/control_plane/priv/repo"],
                 cd: @root,
                 stderr_to_stdout: true
               )

      assert {_output, 0} =
               System.cmd("tar", ["-xf", archive, "-C", directory], stderr_to_stdout: true)

      config = Ankole.Repo.config()

      config =
        config
        |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
        |> Keyword.delete(:url)
        |> Keyword.put(:database, "ankole_release_upgrade_#{System.unique_integer([:positive])}")
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

      # The fixture uses current PostgreSQL. Historical pg_search setup needs vector first.
      SQL.query!(UpgradeRepo, "CREATE EXTENSION IF NOT EXISTS vector")
      historical = Path.join(directory, "app/control_plane/priv/repo/migrations")
      Ecto.Migrator.run(UpgradeRepo, historical, :up, all: true, log: false)
      uid = Ankole.Kernel.gen_uuid_v7()
      marker = "version-check:#{@origin}"

      %{rows: rows} =
        SQL.query!(UpgradeRepo, """
        SELECT column_name FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'principals'
        """)

      columns = List.flatten(rows)

      attributes = [
        {"uid", uid},
        {"display_name", marker},
        {"type", "human"},
        {"status", "active"}
      ]

      attributes =
        if "tenant_id" in columns,
          do: attributes ++ [{"tenant_id", Ecto.UUID.dump!(@default_tenant)}],
          else: attributes

      attributes =
        if "access_version" in columns,
          do: attributes ++ [{"access_version", 1}],
          else: attributes

      names = Enum.map_join(attributes, ",", &elem(&1, 0))
      parameters = Enum.map_join(1..length(attributes), ",", &"$#{&1}")

      SQL.query!(
        UpgradeRepo,
        "INSERT INTO principals (#{names},inserted_at,updated_at) VALUES (#{parameters},now(),now())",
        Enum.map(attributes, &elem(&1, 1))
      )

      pending =
        for {:down, version, _} <- Ecto.Migrator.migrations(UpgradeRepo, @migrations), do: version

      assert pending != []
      assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true, log: false) == pending

      assert %{rows: [[^uid, ^marker, "active"]]} =
               SQL.query!(
                 UpgradeRepo,
                 "SELECT uid,display_name,status FROM principals WHERE uid=$1",
                 [uid]
               )

      assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, all: true, log: false) == []
    end
  end
end
