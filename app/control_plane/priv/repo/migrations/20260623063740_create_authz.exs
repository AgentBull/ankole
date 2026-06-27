defmodule Ankole.Repo.Migrations.CreateAuthz do
  use Ecto.Migration

  def change do
    execute(
      "CREATE TYPE principal_group_kind AS ENUM ('static', 'computed')",
      "DROP TYPE principal_group_kind"
    )

    create table(:principal_groups, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :text, null: false
      add :display_name, :text, null: false
      add :kind, :principal_group_kind, null: false, default: "static"
      add :built_in, :boolean, null: false, default: false
      add :computed_condition, :text
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:principal_groups, [:name])

    create constraint(:principal_groups, :principal_groups_name_present,
             check: "length(btrim(name)) > 0"
           )

    create constraint(:principal_groups, :principal_groups_name_lowercase,
             check: "name = lower(name)"
           )

    create constraint(:principal_groups, :principal_groups_display_name_present,
             check: "length(btrim(display_name)) > 0"
           )

    create constraint(:principal_groups, :principal_groups_computed_condition_by_kind,
             check: """
             (
               kind = 'static'
               AND computed_condition IS NULL
             )
             OR
             (
               kind = 'computed'
               AND computed_condition IS NOT NULL
               AND length(btrim(computed_condition)) > 0
             )
             """
           )

    create constraint(:principal_groups, :principal_groups_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:principal_group_memberships, primary_key: false) do
      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          primary_key: true

      add :group_id,
          references(:principal_groups, type: :uuid, on_delete: :delete_all),
          primary_key: true

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:principal_group_memberships, [:group_id])

    create table(:principal_group_external_bindings, primary_key: false) do
      add :provider, :text, primary_key: true
      add :external_id, :text, primary_key: true

      add :group_id,
          references(:principal_groups, type: :uuid, on_delete: :delete_all),
          null: false

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:principal_group_external_bindings, [:group_id])

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_provider_present,
             check: "length(btrim(provider)) > 0"
           )

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_provider_format,
             check: "provider ~ '^[a-z][a-z0-9_-]*$'"
           )

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_external_id_present,
             check: "length(btrim(external_id)) > 0"
           )

    create constraint(
             :principal_group_external_bindings,
             :principal_group_external_bindings_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    create table(:permission_grants, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :principal_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all)

      add :group_id, references(:principal_groups, type: :uuid, on_delete: :delete_all)
      add :resource_pattern, :text, null: false
      add :action, :text, null: false
      add :condition, :text, null: false, default: "true"
      add :description, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:permission_grants, [:principal_uid, :action])
    create index(:permission_grants, [:group_id, :action])

    create unique_index(
             :permission_grants,
             [:principal_uid, :resource_pattern, :action, :condition],
             name: :permission_grants_principal_natural_index,
             where: "principal_uid IS NOT NULL"
           )

    create unique_index(
             :permission_grants,
             [:group_id, :resource_pattern, :action, :condition],
             name: :permission_grants_group_natural_index,
             where: "group_id IS NOT NULL"
           )

    create constraint(:permission_grants, :permission_grants_owner_shape,
             check: """
             (
               principal_uid IS NOT NULL
               AND group_id IS NULL
             )
             OR
             (
               principal_uid IS NULL
               AND group_id IS NOT NULL
             )
             """
           )

    create constraint(:permission_grants, :permission_grants_resource_pattern_present,
             check: "length(btrim(resource_pattern)) > 0"
           )

    create constraint(:permission_grants, :permission_grants_action_present,
             check: "length(btrim(action)) > 0"
           )

    create constraint(:permission_grants, :permission_grants_action_no_colon,
             check: "position(':' in action) = 0"
           )

    create constraint(:permission_grants, :permission_grants_condition_present,
             check: "length(btrim(condition)) > 0"
           )

    create constraint(:permission_grants, :permission_grants_metadata_object,
             check: "jsonb_typeof(metadata) = 'object'"
           )

    comment_table(:principal_groups, "Authorization groups that collect principals for grants.")

    comment_columns(:principal_groups, %{
      name: "Stable lowercase group name used by policy code and operators.",
      display_name: "Human-readable group name for console and audit views.",
      kind: "Whether membership is explicitly stored or computed from a condition.",
      built_in: "Marks groups created by Ankole rather than by an operator.",
      computed_condition: "Condition expression that defines computed membership.",
      description: "Operator-facing explanation of the group purpose.",
      metadata: "Group metadata that is useful but not part of authorization matching."
    })

    comment_table(:principal_group_memberships, "Explicit static group memberships.")

    comment_columns(:principal_group_memberships, %{
      principal_uid: "Principal that belongs to the group.",
      group_id: "Group receiving the principal membership."
    })

    comment_table(
      :principal_group_external_bindings,
      "Provider group bindings that synchronize or imply Ankole group membership."
    )

    comment_columns(:principal_group_external_bindings, %{
      provider: "External provider namespace for the group binding.",
      external_id: "Provider supplied group identifier.",
      group_id: "Ankole authorization group represented by the external group.",
      metadata: "Provider-specific binding facts kept outside the stable contract."
    })

    comment_table(:permission_grants, "Principal or group grants over resource patterns.")

    comment_columns(:permission_grants, %{
      principal_uid: "Direct principal owner of the grant when the grant is not group-based.",
      group_id: "Group owner of the grant when the grant is not direct to a principal.",
      resource_pattern: "Resource pattern matched by the authorization engine.",
      action: "Action name allowed by this grant.",
      condition: "Condition expression that must evaluate true for the grant to apply.",
      description: "Operator-facing explanation of why the grant exists.",
      metadata: "Grant metadata that is not evaluated by the authorization engine."
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
