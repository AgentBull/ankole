defmodule Ankole.Repo.Migrations.AddBrainSourcesAndCitations do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:brain_retained_sources, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :document_id, :text, null: false

      add :owner_uid,
          references(:principals, column: :uid, type: :text, on_delete: :delete_all),
          null: false

      add :store_key, :text, null: false
      add :capture_method, :text, null: false
      add :title, :text, null: false
      add :origin_locator, :text
      add :original_name, :text
      add :media_type, :text, null: false
      add :byte_size, :bigint, null: false
      add :sha256, :text, null: false
      add :raw_content, :binary, null: false

      add :captured_by_uid, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:brain_retained_sources, [:document_id],
             name: :brain_retained_sources_document_id_index
           )

    create index(:brain_retained_sources, [:owner_uid, :store_key, :inserted_at],
             name: :brain_retained_sources_owner_store_inserted_index
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_document_id_check,
             check: "document_id = 'brain-source:' || id::text"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_store_key_check,
             check: "store_key = 'public' OR (store_key LIKE 'dm:%' AND length(store_key) > 3)"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_capture_method_check,
             check: "capture_method IN ('paste', 'url', 'file')"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_title_present,
             check: "length(btrim(title)) > 0"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_media_type_present,
             check: "length(btrim(media_type)) > 0"
           )

    create constraint(:brain_retained_sources, :brain_retained_sources_content_consistent,
             check:
               "byte_size > 0 AND byte_size = octet_length(raw_content) AND sha256 ~ '^[0-9a-f]{64}$'"
           )

    execute("""
    CREATE FUNCTION reject_brain_retained_source_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'brain retained sources are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER brain_retained_sources_immutable
    BEFORE UPDATE ON brain_retained_sources
    FOR EACH ROW EXECUTE FUNCTION reject_brain_retained_source_update()
    """)

    create table(:brain_block_citations, primary_key: false) do
      add :block_id,
          references(:brain_entry_blocks, type: :uuid, on_delete: :delete_all),
          primary_key: true,
          null: false

      add :document_id, :text, primary_key: true, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:brain_block_citations, [:document_id],
             name: :brain_block_citations_document_id_index
           )

    create constraint(:brain_block_citations, :brain_block_citations_document_id_check,
             check: """
             document_id LIKE 'signal-gateway-entry:%' OR document_id LIKE 'brain-source:%'
             """
           )

    execute("""
    INSERT INTO brain_block_citations (block_id, document_id, inserted_at)
    SELECT DISTINCT
      block.id,
      match[1],
      now()
    FROM brain_entry_blocks AS block
    CROSS JOIN LATERAL regexp_matches(
      block.body,
      '(?<![A-Za-z0-9_-])src:((signal-gateway-entry|brain-source):[A-Za-z0-9_-]+)(?![A-Za-z0-9_-])',
      'g'
    ) AS match
    ON CONFLICT DO NOTHING
    """)

    create unique_index(:brain_entries, [:owner_uid],
             name: :brain_entries_public_curation_guide_index,
             where: "store_key = 'public' AND type = 'brain_curation_guide'"
           )
  end

  def down do
    drop_if_exists index(:brain_entries, [:owner_uid],
                     name: :brain_entries_public_curation_guide_index
                   )

    drop table(:brain_block_citations)

    execute("DROP TRIGGER brain_retained_sources_immutable ON brain_retained_sources")
    execute("DROP FUNCTION reject_brain_retained_source_update()")

    drop table(:brain_retained_sources)
  end
end
