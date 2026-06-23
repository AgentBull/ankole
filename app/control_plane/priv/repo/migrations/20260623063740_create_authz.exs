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
  end
end
