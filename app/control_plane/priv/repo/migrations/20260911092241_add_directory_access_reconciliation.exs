defmodule Ankole.Repo.Migrations.AddDirectoryAccessReconciliation do
  use Ecto.Migration

  def up do
    create table(:identity_directory_states, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_id, :text, null: false
      add :revision, :bigint, null: false, default: 0
      add :status, :text, null: false, default: "unverified"
      add :scope_fingerprint, :text
      add :snapshot_fingerprint, :text
      add :approved_scope_fingerprint, :text
      add :member_uids, {:array, :text}, null: false, default: []
      add :missing_uids, {:array, :text}, null: false, default: []
      add :last_started_at, :utc_datetime_usec
      add :last_success_at, :utc_datetime_usec
      add :last_error, :text
      add :reviewed_by, references(:principals, column: :uid, type: :text, on_delete: :nothing)
      add :reviewed_at, :utc_datetime_usec
      add :review_reason, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:identity_directory_states, [:provider_id])

    create constraint(:identity_directory_states, :identity_directory_states_status,
             check: "status IN ('unverified', 'syncing', 'healthy', 'review_required', 'failed')"
           )

    create table(:identity_directory_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider_id, :text, null: false
      add :event_id, :text, null: false
      add :event_type, :text, null: false
      add :external_ids, {:array, :text}, null: false, default: []
      add :reason, :text
      add :provider_time, :utc_datetime_usec
      add :status, :text, null: false, default: "pending"
      add :last_error, :text
      add :processed_at, :utc_datetime_usec
      add :reviewed_by, references(:principals, column: :uid, type: :text, on_delete: :nothing)
      add :review_reason, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:identity_directory_events, [:provider_id, :event_id])
    create index(:identity_directory_events, [:external_ids], using: :gin)

    create constraint(:identity_directory_events, :identity_directory_events_status,
             check: "status IN ('pending', 'processed', 'review_required', 'dismissed')"
           )

    execute """
    UPDATE app_configurations
    SET key = 'principals.identity_providers.directory_full_sync_interval_minutes',
        value = jsonb_set(value, '{value}', to_jsonb((value->>'value')::bigint * 60))
    WHERE key = 'principals.identity_providers.directory_full_sync_interval_hours'
      AND value->>'type' = 'plaintext'
    """
  end

  def down do
    raise "Directory restrictions and reviewed scope facts must be retained during rollback"
  end
end
