defmodule Ankole.Repo.Migrations.AddFkAndCollectionIndexes do
  use Ecto.Migration

  def up do
    # Page-open & Brain reverse-lookup / FK indexes
    execute("""
    CREATE INDEX brain_links_to_page_id_index
      ON brain_links (tenant_id, to_page_id)
    """)

    execute("""
    CREATE INDEX brain_links_origin_page_id_index
      ON brain_links (tenant_id, origin_page_id)
      WHERE origin_page_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX brain_claims_subject_page_id_index
      ON brain_claims (tenant_id, subject_page_id)
      WHERE subject_page_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX brain_timelines_source_node_id_index
      ON brain_timelines (tenant_id, source_node_id)
    """)

    execute("""
    CREATE INDEX brain_chunks_source_node_id_index
      ON brain_chunks (tenant_id, source_node_id)
    """)

    execute("""
    CREATE INDEX brain_object_aliases_subject_page_id_index
      ON brain_object_aliases (tenant_id, subject_page_id)
    """)

    execute("""
    CREATE INDEX brain_slug_aliases_canonical_page_id_index
      ON brain_slug_aliases (tenant_id, canonical_page_id)
    """)

    execute("""
    CREATE INDEX pages_owner_uid_index
      ON pages (tenant_id, owner_uid)
      WHERE owner_uid IS NOT NULL
    """)

    execute("""
    CREATE INDEX pages_conversation_id_index
      ON pages (tenant_id, conversation_id)
      WHERE conversation_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX pages_message_id_index
      ON pages (tenant_id, message_id)
      WHERE message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX pages_source_conversation_id_index
      ON pages (tenant_id, source_conversation_id)
      WHERE source_conversation_id IS NOT NULL
    """)

    # Conversation / message deletion & retraction FK indexes
    execute("""
    CREATE INDEX deliveries_conversation_id_index
      ON deliveries (tenant_id, conversation_id)
      WHERE conversation_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX deliveries_created_message_id_index
      ON deliveries (tenant_id, created_message_id)
      WHERE created_message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX deliveries_reply_to_message_id_index
      ON deliveries (tenant_id, reply_to_message_id)
      WHERE reply_to_message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX deliveries_target_message_id_index
      ON deliveries (tenant_id, target_message_id)
      WHERE target_message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX signals_conversation_id_index
      ON signals (tenant_id, conversation_id)
      WHERE conversation_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX signals_message_id_index
      ON signals (tenant_id, message_id)
      WHERE message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX signals_ambient_asked_message_id_index
      ON signals (tenant_id, ambient_asked_message_id)
      WHERE ambient_asked_message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX session_ambient_judgments_asked_by_message_id_index
      ON session_ambient_judgments (tenant_id, asked_by_message_id)
      WHERE asked_by_message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX conversation_messages_author_uid_index
      ON conversation_messages (tenant_id, author_uid)
      WHERE author_uid IS NOT NULL
    """)

    execute("""
    CREATE INDEX conversation_messages_reply_to_message_id_index
      ON conversation_messages (tenant_id, conversation_id, reply_to_message_id)
      WHERE reply_to_message_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX conversation_inbound_batches_conversation_id_index
      ON conversation_inbound_batches (tenant_id, conversation_id)
    """)

    # Inbound IM batch entry lookup GIN index
    execute("""
    CREATE INDEX conversation_inbound_batches_entries_index
      ON conversation_inbound_batches USING gin (entries jsonb_path_ops)
    """)

    # Align file_objects_collection_index with tenant-scoped keyset GC scan
    execute("DROP INDEX file_objects_collection_index")

    execute("""
    CREATE INDEX file_objects_collection_index
      ON file_objects (tenant_id, id) INCLUDE (created_at)
    """)
  end

  def down do
    execute("DROP INDEX file_objects_collection_index")

    execute("""
    CREATE INDEX file_objects_collection_index
      ON file_objects (created_at, tenant_id, id)
    """)

    execute("DROP INDEX conversation_inbound_batches_entries_index")
    execute("DROP INDEX conversation_inbound_batches_conversation_id_index")
    execute("DROP INDEX conversation_messages_reply_to_message_id_index")
    execute("DROP INDEX conversation_messages_author_uid_index")
    execute("DROP INDEX session_ambient_judgments_asked_by_message_id_index")
    execute("DROP INDEX signals_ambient_asked_message_id_index")
    execute("DROP INDEX signals_message_id_index")
    execute("DROP INDEX signals_conversation_id_index")
    execute("DROP INDEX deliveries_target_message_id_index")
    execute("DROP INDEX deliveries_reply_to_message_id_index")
    execute("DROP INDEX deliveries_created_message_id_index")
    execute("DROP INDEX deliveries_conversation_id_index")
    execute("DROP INDEX pages_source_conversation_id_index")
    execute("DROP INDEX pages_message_id_index")
    execute("DROP INDEX pages_conversation_id_index")
    execute("DROP INDEX pages_owner_uid_index")
    execute("DROP INDEX brain_slug_aliases_canonical_page_id_index")
    execute("DROP INDEX brain_object_aliases_subject_page_id_index")
    execute("DROP INDEX brain_chunks_source_node_id_index")
    execute("DROP INDEX brain_timelines_source_node_id_index")
    execute("DROP INDEX brain_claims_subject_page_id_index")
    execute("DROP INDEX brain_links_origin_page_id_index")
    execute("DROP INDEX brain_links_to_page_id_index")
  end
end
