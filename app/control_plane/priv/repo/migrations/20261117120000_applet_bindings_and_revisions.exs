defmodule Ankole.Repo.Migrations.AppletBindingsAndRevisions do
  use Ecto.Migration

  def up do
    execute("""
    CREATE TABLE pod_applet_bindings (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id uuid NOT NULL,
      slot_key text NOT NULL CHECK (length(slot_key) > 0),
      table_id uuid,
      field_overrides jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(field_overrides) = 'object'),
      updated_by text NOT NULL,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, page_id, slot_key),
      CONSTRAINT pod_applet_bindings_page_fkey FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE TABLE pod_applet_revisions (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      page_id uuid NOT NULL,
      is_draft boolean NOT NULL DEFAULT false,
      revision bigint,
      base_revision bigint NOT NULL CHECK (base_revision >= 0),
      summary text,
      published_by text,
      routes_signature jsonb NOT NULL DEFAULT '[]',
      actions_signature jsonb NOT NULL DEFAULT '{}',
      restored_from_revision bigint,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id),
      CONSTRAINT pod_applet_revisions_page_fkey FOREIGN KEY (tenant_id, page_id) REFERENCES pages(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT pod_applet_revisions_state CHECK ((is_draft AND revision IS NULL) OR (NOT is_draft AND revision > 0))
    )
    """)

    create unique_index(:pod_applet_revisions, [:tenant_id, :page_id, :revision])

    create unique_index(:pod_applet_revisions, [:tenant_id, :page_id],
             where: "is_draft",
             name: :pod_applet_revisions_draft_index
           )

    execute("""
    CREATE TABLE pod_applet_revision_files (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      revision_id uuid NOT NULL,
      path text NOT NULL,
      object_id uuid NOT NULL,
      content_type text NOT NULL,
      mode integer NOT NULL DEFAULT 420 CHECK (mode BETWEEN 0 AND 511),
      PRIMARY KEY (tenant_id, revision_id, path),
      CONSTRAINT pod_applet_revision_files_revision_fkey FOREIGN KEY (tenant_id, revision_id) REFERENCES pod_applet_revisions(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT pod_applet_revision_files_object_fkey FOREIGN KEY (tenant_id, object_id) REFERENCES file_objects(tenant_id, id)
    )
    """)

    create index(:pod_applet_revision_files, [:tenant_id, :object_id])
  end

  def down do
    drop table(:pod_applet_revision_files)
    drop table(:pod_applet_revisions)
    drop table(:pod_applet_bindings)
  end
end
