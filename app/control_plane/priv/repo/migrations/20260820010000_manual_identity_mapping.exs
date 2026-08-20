defmodule Ankole.Repo.Migrations.ManualIdentityMapping do
  use Ecto.Migration

  def up do
    # platform_subject is the only identity shape that ever had a writer. The
    # reserved channel_actor, login_subject, and outbound_actor kinds and the
    # columns that existed only for them go away with this migration.
    execute("DELETE FROM principal_external_identities WHERE kind <> 'platform_subject'")

    drop(constraint(:principal_external_identities, :principal_external_identities_shape))

    drop(
      index(:principal_external_identities, [:adapter, :channel_id, :external_id],
        name: :principal_external_identities_channel_actor_index
      )
    )

    drop(
      index(:principal_external_identities, [:kind, :provider, :external_id],
        name: :principal_external_identities_provider_identity_index
      )
    )

    alter table(:principal_external_identities) do
      remove :kind
      remove :adapter
      remove :channel_id
      remove :verified_at
      modify :provider, :text, null: false
    end

    execute("DROP TYPE principal_external_identity_kind")

    create unique_index(
             :principal_external_identities,
             [:provider, :external_id],
             name: :principal_external_identities_provider_identity_index
           )

    comment_table(
      :principal_external_identities,
      "External provider subjects bound to principals."
    )

    comment_columns(:principal_external_identities, %{
      provider: "Provider namespace that scopes the external subject id.",
      external_id: "Provider-scoped subject id."
    })

    # Unmapped senders wait here for an operator to bind them to a principal.
    create table(:identity_mapping_requests, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :provider, :text, null: false
      add :external_id, :text, null: false
      add :display_name, :text
      add :email, :text
      add :mobile, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :identity_mapping_requests,
             [:provider, :external_id],
             name: :identity_mapping_requests_subject_index
           )

    create constraint(
             :identity_mapping_requests,
             :identity_mapping_requests_provider_format,
             check: "provider ~ '^[a-z][a-z0-9_-]*$'"
           )

    create constraint(
             :identity_mapping_requests,
             :identity_mapping_requests_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(
      :identity_mapping_requests,
      "Signal senders that could not be mapped to a principal and wait for manual binding."
    )

    comment_columns(:identity_mapping_requests, %{
      provider: "Platform-subject namespace the sender was observed under.",
      external_id: "Primary provider-scoped subject id of the unmapped sender.",
      display_name: "Sender display name captured from the platform, when available.",
      email: "Sender email captured from the platform, when available.",
      mobile: "Sender mobile number captured from the platform, when available.",
      metadata: "Alternate subject ids and observation context for the operator."
    })

    execute(
      "CREATE TYPE signal_unmatched_sender_policy AS ENUM ('manual_review', 'create_standalone')"
    )

    # Every signal binding accumulates its admitted senders into one group so
    # permission policy can address "users of this signal source".
    execute("ALTER TYPE principal_group_domain ADD VALUE IF NOT EXISTS 'signal_source'")

    alter table(:signal_gateway_bindings) do
      add :unmatched_sender_policy, :signal_unmatched_sender_policy,
        null: false,
        default: "manual_review"
    end

    comment_columns(:signal_gateway_bindings, %{
      unmatched_sender_policy:
        "What ingress does with a sender that maps to no principal: hold for manual review or create a standalone account."
    })
  end

  def down do
    alter table(:signal_gateway_bindings) do
      remove :unmatched_sender_policy
    end

    execute("DROP TYPE signal_unmatched_sender_policy")

    drop(table(:identity_mapping_requests))

    execute("""
    CREATE TYPE principal_external_identity_kind AS ENUM (
      'platform_subject',
      'channel_actor',
      'login_subject',
      'outbound_actor'
    )
    """)

    drop(
      index(:principal_external_identities, [:provider, :external_id],
        name: :principal_external_identities_provider_identity_index
      )
    )

    alter table(:principal_external_identities) do
      add :kind, :principal_external_identity_kind, null: false, default: "platform_subject"
      add :adapter, :text
      add :channel_id, :text
      add :verified_at, :utc_datetime_usec
      modify :provider, :text, null: true
    end

    execute("ALTER TABLE principal_external_identities ALTER COLUMN kind DROP DEFAULT")

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
  end

  defp comment_table(table, comment) do
    execute("COMMENT ON TABLE #{identifier(table)} IS #{literal(comment)}")
  end

  defp comment_columns(table, comments) do
    Enum.each(comments, fn {column, comment} ->
      execute(
        "COMMENT ON COLUMN #{identifier(table)}.#{identifier(column)} IS #{literal(comment)}"
      )
    end)
  end

  defp identifier(value), do: "\"" <> String.replace(to_string(value), "\"", "\"\"") <> "\""
  defp literal(value), do: "'" <> String.replace(value, "'", "''") <> "'"
end
