defmodule Ankole.Repo.Migrations.CreateFiles do
  use Ecto.Migration

  def change do
    create table(:files, primary_key: false) do
      add :sha256, :binary, primary_key: true
      add :size, :bigint, null: false
      add :deleting, :boolean, null: false, default: false
      add :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :last_referenced_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create constraint(:files, :files_sha256_length, check: "octet_length(sha256) = 32")
    create constraint(:files, :files_size_non_negative, check: "size >= 0")
    create index(:files, [:last_referenced_at], where: "NOT deleting")
    create index(:files, [:sha256], where: "deleting", name: :files_deleting_index)

    create table(:agent_files, primary_key: false) do
      add :agent_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :path, :text, primary_key: true

      add :sha256, references(:files, column: :sha256, type: :binary, on_delete: :restrict),
        null: false

      add :mode, :integer, null: false, default: 420
      add :content_type, :text, null: false
      add :source, :text, null: false
      add :signal_channel_id, :text
      add :source_entry_id, :text
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:agent_files, :agent_files_source,
             check: "source IN ('inbound', 'generated', 'sent', 'agent', 'console')"
           )

    create constraint(:agent_files, :agent_files_path_shape,
             check:
               "length(path) BETWEEN 1 AND 1024 AND left(path, 1) <> '/' AND right(path, 1) <> '/'"
           )

    create constraint(:agent_files, :agent_files_mode, check: "mode BETWEEN 0 AND 511")
    create index(:agent_files, [:sha256])
  end
end
