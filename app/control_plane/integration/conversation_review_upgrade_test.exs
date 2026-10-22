defmodule Ankole.ConversationReviewUpgradeIntegrationTest do
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL

  defmodule UpgradeRepo do
    use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  end

  @moduletag timeout: 180_000
  @tenant "019a2b00-0000-7000-8000-000000000001"

  test "upgrade merges observer deletion guards without an Agent owner" do
    config = Ankole.Repo.config()

    config =
      config
      |> Keyword.merge(Ecto.Repo.Supervisor.parse_url(config[:url] || ""))
      |> Keyword.delete(:url)
      |> Keyword.put(
        :database,
        "ankole_conversation_review_#{System.unique_integer([:positive])}"
      )
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:log, false)

    assert :ok = Ecto.Adapters.Postgres.storage_up(config)
    {:ok, pid} = UpgradeRepo.start_link(config)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: Supervisor.stop(pid)
      :ok = Ecto.Adapters.Postgres.storage_down(config)
    end)

    migrations = Path.expand("../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_261_014_000_400, log: false)

    now = DateTime.utc_now(:microsecond)

    agents =
      for _ <- 1..2 do
        uid = Ankole.Kernel.gen_uuid_v7()

        {1, nil} =
          UpgradeRepo.insert_all("principals", [
            %{
              uid: uid,
              tenant_id: Ecto.UUID.dump!(@tenant),
              type: "agent",
              display_name: "Observer",
              status: "active",
              access_version: 1,
              inserted_at: now,
              updated_at: now
            }
          ])

        %{uid: uid}
      end

    [first, second] = agents
    room = %{id: Ankole.Kernel.gen_uuid_v7()}

    {1, nil} =
      UpgradeRepo.insert_all("conversations", [
        %{
          id: Ecto.UUID.dump!(room.id),
          tenant_id: Ecto.UUID.dump!(@tenant),
          kind: "external",
          title: "Shared room",
          provider_conversation_id: "lark:upgrade-review",
          external_kind: "im_group",
          reply_mode: "entry",
          last_activity_at: now,
          first_seen_at: now,
          last_seen_at: now,
          inserted_at: now,
          updated_at: now
        }
      ])

    for {agent, binding, until} <- [
          {first, "first", "2026-10-16 01:00:00"},
          {second, "second", "2026-10-16 02:00:00"},
          {first, "other", "2026-10-16 00:00:00"}
        ] do
      SQL.query!(UpgradeRepo, """
      INSERT INTO conversation_input_tombstones
        (tenant_id, agent_uid, binding_name, conversation_id, provider_message_id,
         tombstoned_until, inserted_at, updated_at)
      VALUES ('#{@tenant}', '#{agent.uid}', '#{binding}', '#{room.id}', 'removed',
        '#{until}', '2026-10-15 00:00:00', '2026-10-15 01:00:00')
      """)
    end

    assert Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_261_015_000_100, log: false) ==
             [
               20_261_015_000_100
             ]

    assert %{rows: [["removed", ~N[2026-10-16 02:00:00.000000]]]} =
             SQL.query!(
               UpgradeRepo,
               "SELECT provider_message_id, tombstoned_until FROM conversation_input_tombstones"
             )

    # Removing an observer must not remove the shared ordering guard.
    assert %{num_rows: 1} =
             SQL.query!(UpgradeRepo, "DELETE FROM principals WHERE tenant_id = $1 AND uid = $2", [
               Ecto.UUID.dump!(@tenant),
               second.uid
             ])

    assert %{rows: [[1]]} =
             SQL.query!(UpgradeRepo, "SELECT count(*) FROM conversation_input_tombstones")

    assert Ecto.Migrator.run(UpgradeRepo, migrations, :up, to: 20_261_015_000_100, log: false) ==
             []
  end
end
