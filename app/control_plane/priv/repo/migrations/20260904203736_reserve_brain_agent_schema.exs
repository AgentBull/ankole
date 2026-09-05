defmodule Ankole.Repo.Migrations.ReserveBrainAgentSchema do
  use Ecto.Migration

  def up do
    Enum.each(up_sqls(), &execute/1)
  end

  def up_sqls do
    [
      """
      UPDATE brain_schema_types
      SET subtypes = '["internal"]'::jsonb
      WHERE name = 'agent'
      """,
      """
      UPDATE brain_schema_packs AS pack
      SET version = '1.1.1',
          content_hash = '803f80f51c28c0120a3440fdc798f7d9',
          manifest = jsonb_set(
            jsonb_set(pack.manifest, '{page_types}', (
              SELECT jsonb_agg(
                CASE WHEN declaration->>'name' = 'agent'
                     THEN jsonb_set(declaration, '{subtypes}', '["internal"]'::jsonb)
                     ELSE declaration END ORDER BY position
              )
              FROM jsonb_array_elements(pack.manifest->'page_types')
                WITH ORDINALITY AS entries(declaration, position)
            )), '{version}', '"1.1.1"'::jsonb)
      WHERE pack.name = 'general' AND pack.version = '1.1.0'
      """
    ]
  end

  def down do
    raise Ecto.MigrationError, message: "the Agent namespace remains reserved for Principals"
  end
end
