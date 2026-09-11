defmodule Ankole.Repo.Migrations.AddHumanAccessRevocation do
  use Ecto.Migration

  def change do
    alter table(:principals) do
      add :access_version, :bigint, null: false, default: 1
    end

    create constraint(:principals, :principals_access_version_positive,
             check: "access_version > 0"
           )

    create table(:human_access_restrictions, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :principal_uid, references(:human_users, column: :principal_uid, type: :text),
        null: false

      add :source, :text, null: false
      add :reason, :text, null: false
      add :operation_id, :text, null: false
      add :provider_time, :utc_datetime_usec
      add :recovery_verified_at, :utc_datetime_usec
      add :cleared_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:human_access_restrictions, [:principal_uid, :source, :reason],
             where: "cleared_at IS NULL",
             name: :human_access_restrictions_active_index
           )

    create table(:human_access_events, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :principal_uid, references(:human_users, column: :principal_uid, type: :text),
        null: false

      add :operation_id, :text, null: false
      add :source, :text, null: false
      add :action, :text, null: false
      add :reason, :text, null: false
      add :actor_uid, :text
      add :previous_status, :text, null: false
      add :status, :text, null: false
      add :access_version, :bigint, null: false
      add :provider_time, :utc_datetime_usec
      add :details, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:human_access_events, [:source, :operation_id, :principal_uid])
    create index(:human_access_events, [:principal_uid, :inserted_at])

    execute(
      fn ->
        %{rows: rows} =
          repo().query!("SELECT uid FROM principals WHERE type = 'human' AND status = 'disabled'")

        Enum.each(rows, fn [uid] ->
          repo().query!(
            """
            INSERT INTO human_access_restrictions
              (id, principal_uid, source, reason, operation_id, inserted_at, updated_at)
            VALUES ($1::uuid, $2, 'manual', 'legacy_disable', 'migration', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
            """,
            [Ecto.UUID.dump!(Ankole.Kernel.gen_uuid_v7()), uid]
          )
        end)
      end,
      fn ->
        repo().query!("DELETE FROM human_access_restrictions WHERE operation_id = 'migration'")
      end
    )
  end
end
