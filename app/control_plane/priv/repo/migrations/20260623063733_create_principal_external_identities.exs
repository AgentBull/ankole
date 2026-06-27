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

    comment_table(
      :principal_external_identities,
      "External identity bindings that connect principals to providers, channels, and login subjects."
    )

    comment_columns(:principal_external_identities, %{
      principal_uid: "Principal represented by this external identity.",
      kind: "Identity shape: platform subject, channel actor, login subject, or outbound actor.",
      provider: "Provider namespace for non-channel identities.",
      adapter: "SignalsGateway adapter namespace for channel actor identities.",
      channel_id: "Provider channel id when the identity belongs to a channel actor.",
      external_id: "Provider supplied subject or actor identifier.",
      verified_at: "Time this identity binding was last proven by the provider.",
      metadata: "Provider-specific identity facts kept outside the stable contract."
    })
  end

  defp comment_table(table, comment) do
    execute(
      "COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}",
      "COMMENT ON TABLE #{identifier(table)} IS NULL"
    )
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} -> comment_column(table, column, comment) end)
  end

  defp comment_column(table, column, comment) do
    execute(
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}",
      "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS NULL"
    )
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
