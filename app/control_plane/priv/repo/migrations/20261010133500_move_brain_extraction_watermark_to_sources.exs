defmodule Ankole.Repo.Migrations.MoveBrainExtractionWatermarkToSources do
  use Ecto.Migration

  @newest """
  SELECT DISTINCT ON (c.tenant_id, c.signal_gateway_channel_id)
         c.tenant_id, c.signal_gateway_channel_id AS channel_id, c.valid_from, c.context
  FROM brain_claims c
  WHERE c.provenance LIKE 'ankole-brain-internal:%'
  ORDER BY c.tenant_id, c.signal_gateway_channel_id, c.valid_from DESC, c.created_at DESC
  """

  def up do
    alter table(:brain_sources) do
      add :extracted_through_at, :utc_datetime_usec
      add :extracted_through_entry_id, :text
    end

    create constraint(:brain_sources, :brain_sources_extraction_watermark_pair,
             check: "num_nonnulls(extracted_through_at, extracted_through_entry_id) IN (0, 2)"
           )

    execute """
    WITH newest AS (#{@newest})
    UPDATE brain_sources s
    SET extracted_through_at = n.valid_from,
        extracted_through_entry_id = n.context
    FROM newest n
    WHERE s.tenant_id = n.tenant_id
      AND s.kind = 'signal_channel'
      AND s.upstream_id = n.channel_id;
    """

    execute """
    DO $$
    DECLARE mismatched bigint;
    BEGIN
      WITH newest AS (#{@newest})
      SELECT count(*) INTO mismatched FROM (
        SELECT n.channel_id
        FROM newest n
        LEFT JOIN brain_sources s
          ON s.tenant_id = n.tenant_id AND s.kind = 'signal_channel' AND s.upstream_id = n.channel_id
        WHERE s.id IS NULL
           OR s.extracted_through_at IS DISTINCT FROM n.valid_from
           OR s.extracted_through_entry_id IS DISTINCT FROM n.context
        UNION ALL
        SELECT s.upstream_id
        FROM brain_sources s
        WHERE s.extracted_through_at IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM newest n
            WHERE s.kind = 'signal_channel' AND n.tenant_id = s.tenant_id AND n.channel_id = s.upstream_id)
      ) AS mismatch;
      IF mismatched > 0 THEN
        RAISE EXCEPTION 'Brain extraction watermark move found % mismatched channel(s); nothing was changed.', mismatched;
      END IF;
    END $$;
    """

    execute "DELETE FROM brain_claims WHERE provenance LIKE 'ankole-brain-internal:%'"
    execute "DROP INDEX brain_claims_extraction_terminal_key"
  end

  def down do
    raise Ecto.MigrationError,
      message: "Brain extraction watermarks moved to Sources; restore the pre-upgrade backup"
  end
end
