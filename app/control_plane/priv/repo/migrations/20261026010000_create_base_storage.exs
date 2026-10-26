defmodule Ankole.Repo.Migrations.CreateBaseStorage do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add :base_db_id, :text
    end

    flush()

    for [id] <- repo().query!("SELECT id::text FROM tenants", []).rows do
      {:ok, shard} = Ankole.Pod.BaseCluster.allocate(id)
      repo().query!("UPDATE tenants SET base_db_id=$1 WHERE id=$2::text::uuid", [shard, id])
    end

    execute "ALTER TABLE tenants ALTER COLUMN base_db_id SET NOT NULL"

    execute "ALTER TABLE pages DROP CONSTRAINT pages_type_check"
    execute "UPDATE pages SET type='base' WHERE type='database'"

    execute "ALTER TABLE pages ADD CONSTRAINT pages_type_check CHECK(type IN ('doc','base','applet','file'))"

    for suffix <- ~w(tables fields views records) do
      execute "ALTER TABLE db_#{suffix} RENAME TO base_#{suffix}"
    end

    execute """
    DO $$ DECLARE item record; BEGIN
      FOR item IN SELECT conname, conrelid::regclass AS rel FROM pg_constraint
        WHERE conrelid IN ('base_tables'::regclass,'base_fields'::regclass,'base_views'::regclass,'base_records'::regclass)
          AND conname LIKE 'db_%'
      LOOP EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I',item.rel,item.conname,'base_'||substring(item.conname from 4)); END LOOP;
      FOR item IN SELECT indexname FROM pg_indexes WHERE schemaname='public' AND indexname LIKE 'db_%'
      LOOP EXECUTE format('ALTER INDEX %I RENAME TO %I',item.indexname,'base_'||substring(item.indexname from 4)); END LOOP;
    END $$
    """

    execute "DROP INDEX base_records_data_index"

    execute "ALTER TABLE base_fields ADD CONSTRAINT base_fields_primary_text CHECK (NOT is_primary OR type = 'text')"

    execute """
    ALTER TABLE base_tables
      ADD COLUMN storage_mode text NOT NULL DEFAULT 'inline' CHECK(storage_mode IN ('inline','physical')),
      ADD COLUMN schema_version bigint NOT NULL DEFAULT 0 CHECK(schema_version >= 0),
      ADD COLUMN record_bytes bigint NOT NULL DEFAULT 0 CHECK(record_bytes >= 0),
      ADD COLUMN deleting_at timestamptz
    """

    execute "ALTER TABLE base_records ADD COLUMN data_bytes integer GENERATED ALWAYS AS (octet_length(data::text)) STORED"
  end

  def down, do: raise("Base storage requires a database restore to roll back")
end
