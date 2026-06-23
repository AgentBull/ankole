defmodule Ankole.Repo.Migrations.CreatePrincipalExternalIdentities do
  use Ecto.Migration

  def change do
    execute(
      """
      CREATE TYPE principal_external_identity_kind AS ENUM (
        'platform_subject',
        'channel_actor',
        'login_subject',
        'outbound_actor'
      )
      """,
      "DROP TYPE principal_external_identity_kind"
    )

    create table(:principal_external_identities, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :kind, :principal_external_identity_kind, null: false
      add :provider, :text
      add :adapter, :text
      add :channel_id, :text
      add :external_id, :text
      add :verified_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:principal_external_identities, [:principal_uid])

    create unique_index(
             :principal_external_identities,
             [:adapter, :channel_id, :external_id],
             name: :principal_external_identities_channel_actor_index,
             where: "kind = 'channel_actor'"
           )

    create unique_index(
             :principal_external_identities,
             [:kind, :provider, :external_id],
             name: :principal_external_identities_provider_identity_index,
             where: "kind <> 'channel_actor'"
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_shape,
             check: """
             (
               kind = 'channel_actor'
               AND provider IS NULL
               AND adapter IS NOT NULL
               AND channel_id IS NOT NULL
               AND external_id IS NOT NULL
             )
             OR
             (
               kind <> 'channel_actor'
               AND provider IS NOT NULL
               AND adapter IS NULL
               AND channel_id IS NULL
               AND external_id IS NOT NULL
             )
             """
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_provider_format,
             check: "provider IS NULL OR provider ~ '^[a-z][a-z0-9_-]*$'"
           )

    create constraint(
             :principal_external_identities,
             :principal_external_identities_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )
  end
end
