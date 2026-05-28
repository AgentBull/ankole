defmodule BullX.Repo.Migrations.CreatePrincipalAuthnTables do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE principal_type AS ENUM ('human', 'agent')",
      "DROP TYPE principal_type"
    )

    execute(
      "CREATE TYPE principal_status AS ENUM ('active', 'disabled')",
      "DROP TYPE principal_status"
    )

    execute(
      "CREATE TYPE principal_external_identity_kind AS ENUM ('channel_actor', 'login_subject', 'outbound_actor')",
      "DROP TYPE principal_external_identity_kind"
    )

    create table(:principals, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :uid, :text, null: false
      add :type, :principal_type, null: false
      add :status, :principal_status, null: false
      add :display_name, :text
      add :bio, :text
      add :avatar_url, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:principals, [:uid])
    create constraint(:principals, :principals_uid_lowercase, check: "uid = lower(uid)")

    create table(:human_users, primary_key: false) do
      add :principal_id, references(:principals, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :email, :text
      add :phone, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:human_users, [:email], where: "email IS NOT NULL")
    create unique_index(:human_users, [:phone], where: "phone IS NOT NULL")

    create table(:agents, primary_key: false) do
      add :principal_id, references(:principals, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :profile, :map, null: false, default: %{}

      add :created_by_principal_id, references(:principals, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agents, [:created_by_principal_id])
    create constraint(:agents, :agents_profile_object, check: "jsonb_typeof(profile) = 'object'")

    create table(:principal_external_identities, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :principal_id, references(:principals, type: :uuid, on_delete: :delete_all), null: false
      add :kind, :principal_external_identity_kind, null: false
      add :provider, :text
      add :adapter, :text
      add :channel_id, :text
      add :external_id, :text
      add :verified_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:principal_external_identities, [:principal_id])

    create unique_index(
             :principal_external_identities,
             [:adapter, :channel_id, :external_id],
             name: :principal_external_identities_channel_actor_index,
             where: "kind = 'channel_actor'"
           )

    create unique_index(
             :principal_external_identities,
             [:provider, :external_id],
             name: :principal_external_identities_login_subject_index,
             where: "kind = 'login_subject'"
           )

    create unique_index(
             :principal_external_identities,
             [:provider, :external_id],
             name: :principal_external_identities_outbound_actor_index,
             where: "kind = 'outbound_actor'"
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_channel_actor_required,
             check:
               "(kind <> 'channel_actor') OR (adapter IS NOT NULL AND channel_id IS NOT NULL AND external_id IS NOT NULL)"
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_provider_subject_required,
             check:
               "(kind NOT IN ('login_subject', 'outbound_actor')) OR (provider IS NOT NULL AND external_id IS NOT NULL)"
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:principal_login_auth_codes, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :code_hash, :text, null: false
      add :principal_id, references(:principals, type: :uuid, on_delete: :delete_all), null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:principal_login_auth_codes, [:code_hash])
    create index(:principal_login_auth_codes, [:principal_id])
    create index(:principal_login_auth_codes, [:inserted_at])

    create constraint(
             :principal_login_auth_codes,
             :principal_login_auth_codes_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end
end
