defmodule Ankole.Repo.Migrations.ScopePrincipalPrimaryKeys do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      refs jsonb;
      ref jsonb;
      parent text;
      uid_column text;
      definition text;
      redundant record;
    BEGIN
      SELECT jsonb_agg(jsonb_build_object(
        'table', conrelid::regclass::text, 'name', conname,
        'definition', pg_get_constraintdef(oid))) INTO refs
      FROM pg_constraint
      WHERE contype = 'f' AND (confrelid IN
        ('principals'::regclass, 'agents'::regclass,
         'human_users'::regclass, 'agent_workers'::regclass)
        OR conname = 'delivery_attachments_delivery_fkey');

      FOR ref IN SELECT * FROM jsonb_array_elements(refs) LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', ref->>'table', ref->>'name');
      END LOOP;

      FOREACH parent IN ARRAY ARRAY['principals', 'agents', 'human_users', 'agent_workers'] LOOP
        uid_column := CASE parent WHEN 'human_users' THEN 'principal_uid'
          WHEN 'agent_workers' THEN 'agent_uid' ELSE 'uid' END;
        EXECUTE format('ALTER TABLE %I DROP CONSTRAINT %I', parent, parent || '_pkey');

        FOR redundant IN
          SELECT indexrelid::regclass::text AS name FROM pg_index
          WHERE indrelid = parent::regclass AND indisunique
            AND indnkeyatts = 2 AND indpred IS NULL
            AND (SELECT array_agg(a.attname::text ORDER BY a.attname)
                 FROM unnest(indkey) AS k(attnum)
                 JOIN pg_attribute a ON a.attrelid = indrelid AND a.attnum = k.attnum)
                = (SELECT array_agg(n ORDER BY n) FROM unnest(ARRAY['tenant_id', uid_column]) AS n)
        LOOP
          EXECUTE format('DROP INDEX %s', redundant.name);
        END LOOP;

        EXECUTE format('ALTER TABLE %I ADD PRIMARY KEY (tenant_id, %I)', parent, uid_column);
      END LOOP;

      FOR ref IN SELECT * FROM jsonb_array_elements(refs) LOOP
        definition := regexp_replace(ref->>'definition',
          ' ON UPDATE (NO ACTION|RESTRICT|CASCADE|SET NULL|SET DEFAULT)', '');
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s ON UPDATE CASCADE',
          ref->>'table', ref->>'name', definition);
      END LOOP;
    END $$;
    """)
  end

  def down do
    raise Ecto.MigrationError,
          "Tenant-local Principal names cannot be converted to globally unique names automatically"
  end
end
