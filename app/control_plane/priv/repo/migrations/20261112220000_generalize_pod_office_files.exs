defmodule Ankole.Repo.Migrations.GeneralizePodOfficeFiles do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE pod_spreadsheet_ops RENAME TO pod_office_ops")

    execute("""
    DO $$ DECLARE item record; BEGIN
      FOR item IN SELECT conname FROM pg_constraint WHERE conrelid = 'pod_office_ops'::regclass
        AND conname LIKE 'pod_spreadsheet_ops_%'
      LOOP
        EXECUTE format('ALTER TABLE pod_office_ops RENAME CONSTRAINT %I TO %I', item.conname,
          replace(item.conname, 'pod_spreadsheet_ops_', 'pod_office_ops_'));
      END LOOP;
      FOR item IN SELECT indexname FROM pg_indexes WHERE tablename = 'pod_office_ops'
        AND schemaname = current_schema()
        AND indexname LIKE 'pod_spreadsheet_ops_%'
      LOOP
        EXECUTE format('ALTER INDEX %I RENAME TO %I', item.indexname,
          replace(item.indexname, 'pod_spreadsheet_ops_', 'pod_office_ops_'));
      END LOOP;
    END $$
    """)

    execute("""
    CREATE TABLE pod_office_checkpoints (
      tenant_id  uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      page_id    uuid NOT NULL,
      object_id  uuid NOT NULL,
      checkpoint text NOT NULL,
      updated_at timestamptz NOT NULL,
      PRIMARY KEY (tenant_id, page_id),
      FOREIGN KEY (tenant_id, page_id) REFERENCES pages (tenant_id, id) ON DELETE CASCADE
    )
    """)

    execute("""
    UPDATE app_configurations
      SET key = 'pod.office.limits'
      WHERE key = 'pod.spreadsheet.limits'
    """)

    execute("""
    UPDATE site_app_configurations
      SET key = 'pod.office.limits'
      WHERE key = 'pod.spreadsheet.limits'
    """)

    execute("""
    UPDATE oban_jobs
      SET worker = 'Ankole.Pod.Jobs.CompactOfficeFile'
      WHERE worker = 'Ankole.Pod.Jobs.CompactSpreadsheet'
    """)
  end

  def down do
    execute("DROP TABLE pod_office_checkpoints")

    execute("""
    UPDATE oban_jobs
      SET worker = 'Ankole.Pod.Jobs.CompactSpreadsheet'
      WHERE worker = 'Ankole.Pod.Jobs.CompactOfficeFile'
    """)

    execute("""
    UPDATE site_app_configurations
      SET key = 'pod.spreadsheet.limits'
      WHERE key = 'pod.office.limits'
    """)

    execute("""
    UPDATE app_configurations
      SET key = 'pod.spreadsheet.limits'
      WHERE key = 'pod.office.limits'
    """)

    execute("""
    DO $$ DECLARE item record; BEGIN
      FOR item IN SELECT conname FROM pg_constraint WHERE conrelid = 'pod_office_ops'::regclass
        AND conname LIKE 'pod_office_ops_%'
      LOOP
        EXECUTE format('ALTER TABLE pod_office_ops RENAME CONSTRAINT %I TO %I', item.conname,
          replace(item.conname, 'pod_office_ops_', 'pod_spreadsheet_ops_'));
      END LOOP;
      FOR item IN SELECT indexname FROM pg_indexes WHERE tablename = 'pod_office_ops'
        AND schemaname = current_schema()
        AND indexname LIKE 'pod_office_ops_%'
      LOOP
        EXECUTE format('ALTER INDEX %I RENAME TO %I', item.indexname,
          replace(item.indexname, 'pod_office_ops_', 'pod_spreadsheet_ops_'));
      END LOOP;
    END $$
    """)

    execute("ALTER TABLE pod_office_ops RENAME TO pod_spreadsheet_ops")
  end
end
