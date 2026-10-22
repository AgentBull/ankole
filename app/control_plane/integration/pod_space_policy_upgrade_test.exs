defmodule Ankole.Pod.SpacePolicyUpgradeTest do
  use Ankole.DataCase, async: false

  alias Ecto.Adapters.SQL

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  @moduletag timeout: 180_000
  @migrations Path.expand("../priv/repo/migrations", __DIR__)
  @migration 20_261_019_120_000

  test "initial policy uses the upgrading database and keeps tenant scopes separate" do
    config = Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(:database, "ankole_pod_policy_upgrade_#{System.unique_integer([:positive])}")
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

    second_id = Ankole.Ecto.UUIDv7.autogenerate()
    now = DateTime.utc_now(:microsecond)

    UpgradeRepo.insert_all("tenants", [
      %{
        id: Ecto.UUID.dump!(second_id),
        slug: "other",
        display_name: "Other tenant",
        inserted_at: now,
        updated_at: now
      }
    ])

    assert SQL.query!(
             UpgradeRepo,
             "SELECT count(*) FROM permission_grants WHERE action LIKE 'page_%'"
           ).rows == [[0]]

    before = Repo.all(Ankole.AuthZ.Grant)
    dynamic_repo = Repo.get_dynamic_repo()

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration, log: false) == [
             @migration
           ]

    assert SQL.query!(UpgradeRepo, """
           SELECT g.tenant_id::text, count(*) FROM permission_grants g
           JOIN principal_groups p ON g.group_id = p.id AND g.tenant_id = p.tenant_id
           WHERE p.name = 'all_humans' AND g.action IN ('page_view', 'page_edit', 'page_manage')
             AND g.condition = 'true' AND g.resource_pattern = 'pod:space:**'
           GROUP BY g.tenant_id ORDER BY g.tenant_id
           """).rows == [["019a2b00-0000-7000-8000-000000000001", 3], [second_id, 3]]

    assert Ecto.Migrator.run(UpgradeRepo, @migrations, :up, to: @migration, log: false) == []
    assert Repo.get_dynamic_repo() == dynamic_repo
    assert Repo.all(Ankole.AuthZ.Grant) == before
  end
end
