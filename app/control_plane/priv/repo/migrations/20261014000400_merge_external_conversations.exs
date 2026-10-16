Code.require_file("../migration_support/signal_producers.exs", __DIR__)

defmodule Ankole.Repo.Migrations.MergeExternalConversations do
  use Ecto.Migration

  @renames [
    {"signal_gateway_bindings", "signal_bindings"},
    {"signal_gateway_outbox_entries", "deliveries"},
    {"signal_gateway_inbound_batches", "conversation_inbound_batches"},
    {"signal_gateway_input_tombstones", "conversation_input_tombstones"},
    {"signal_gateway_ambient_judgments", "session_ambient_judgments"},
    {"signal_gateway_webhook_endpoints", "signal_webhook_endpoints"}
  ]

  # Text that a uuid column can be compared with; other strings never match a row.
  @uuid_pattern "'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'"

  def up do
    execute(fn ->
      repo = repo()
      # A server-side statement_timeout from the site's role or database would
      # cancel the rewrite; the setting ends with this transaction.
      sql(repo, "SET LOCAL statement_timeout = 0")

      if Ankole.Repo.Migrations.SignalProducers.add_if_missing(repo),
        do: Ankole.Repo.Migrations.SignalProducers.backfill(repo)

      expand_schema(repo)
      prepare_maps(repo)
      copy_public_records(repo)
      migrate_columns(repo)
      migrate_session_keys(repo)
      migrate_brain(repo)
      migrate_files(repo)
      migrate_typed_json(repo)
      migrate_addressed_signals(repo)
      migrate_jobs(repo)
      retire_old_records(repo)
      rename_tables(repo)
      migrate_signal_configuration(repo)
      migrate_deliveries(repo)
      finish_constraints(repo)
    end)
  end

  def down do
    raise Ecto.MigrationError,
      message: "restore the pre-upgrade database backup and its matching runtime code"
  end

  defp expand_schema(repo) do
    sql(repo, """
    ALTER TABLE conversations DROP CONSTRAINT conversations_kind_check;
    DROP INDEX conversation_participants_one_agent_index;
    ALTER TABLE conversations ALTER COLUMN created_by DROP NOT NULL;
    ALTER TABLE conversations ADD COLUMN sequence_high_water bigint NOT NULL DEFAULT 0 CHECK (sequence_high_water>=0);
    ALTER TABLE conversations ADD COLUMN provider_conversation_id text;
    ALTER TABLE conversations ADD COLUMN external_kind text;
    ALTER TABLE conversations ADD COLUMN reply_mode text;
    ALTER TABLE conversations ADD COLUMN visibility text;
    ALTER TABLE conversations ADD COLUMN principal_group_id uuid;
    ALTER TABLE conversations ADD COLUMN metadata jsonb NOT NULL DEFAULT '{}';
    ALTER TABLE conversations ADD COLUMN raw_payload jsonb NOT NULL DEFAULT '{}';
    ALTER TABLE conversations ADD COLUMN first_seen_at timestamp(6) without time zone;
    ALTER TABLE conversations ADD COLUMN last_seen_at timestamp(6) without time zone;
    ALTER TABLE conversations ADD COLUMN ambient_standing_orders text;
    ALTER TABLE conversations ADD COLUMN ambient_standing_orders_set_by text;
    ALTER TABLE conversations ADD COLUMN ambient_standing_orders_updated_at timestamp(6) without time zone;
    ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_author_type_check;
    ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_text_present;
    ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_origin_check;
    ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_provenance_check;
    ALTER TABLE conversation_messages ALTER COLUMN author_uid DROP NOT NULL;
    ALTER TABLE conversation_messages ALTER COLUMN text DROP NOT NULL;
    ALTER TABLE conversation_messages ADD COLUMN attachments jsonb[] NOT NULL DEFAULT '{}';
    ALTER TABLE conversation_messages ADD COLUMN links jsonb[] NOT NULL DEFAULT '{}';
    ALTER TABLE conversation_messages ADD COLUMN mentions jsonb[] NOT NULL DEFAULT '{}';
    ALTER TABLE conversation_messages ADD COLUMN rich_content jsonb;
    DROP INDEX conversation_messages_signal_index;
    ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_author_uid_fkey;
    ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_author_uid_fkey
      FOREIGN KEY (tenant_id, author_uid) REFERENCES principals (tenant_id, uid)
      ON DELETE SET NULL (author_uid);
    ALTER TABLE conversation_messages DROP CONSTRAINT conversation_messages_signal_id_fkey;
    ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_signal_id_fkey
      FOREIGN KEY (tenant_id,signal_id) REFERENCES signals(tenant_id,id) ON DELETE SET NULL (signal_id);
    CREATE TABLE external_message_refs (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      message_id uuid NOT NULL,
      conversation_id uuid NOT NULL,
      provider_message_id text NOT NULL CHECK (btrim(provider_message_id) <> ''),
      reply_to_provider_message_id text,
      provider_thread_id text,
      author jsonb NOT NULL DEFAULT '{}',
      metadata jsonb NOT NULL DEFAULT '{}',
      raw_payload jsonb NOT NULL DEFAULT '{}',
      provider_time timestamp(6) without time zone,
      reactions jsonb NOT NULL DEFAULT '{}',
      raw_reaction_keys jsonb NOT NULL DEFAULT '{}',
      content_hash text,
      first_seen_at timestamp(6) without time zone NOT NULL,
      last_seen_at timestamp(6) without time zone NOT NULL,
      ai_message_id uuid,
      PRIMARY KEY (tenant_id, message_id),
      CONSTRAINT external_message_refs_message_id_fkey
        FOREIGN KEY (tenant_id, conversation_id, message_id)
        REFERENCES conversation_messages(tenant_id, conversation_id, id) ON DELETE CASCADE,
      CONSTRAINT external_message_refs_conversation_id_fkey
        FOREIGN KEY (tenant_id, conversation_id) REFERENCES conversations(tenant_id, id) ON DELETE CASCADE,
      CONSTRAINT external_message_refs_objects_check CHECK (
        jsonb_typeof(author) = 'object' AND jsonb_typeof(metadata) = 'object' AND
        jsonb_typeof(raw_payload) = 'object' AND jsonb_typeof(reactions) = 'object' AND
        jsonb_typeof(raw_reaction_keys) = 'object')
    );
    CREATE UNIQUE INDEX external_message_refs_provider_identity_index
      ON external_message_refs(tenant_id, conversation_id, provider_message_id);
    CREATE TEMP TABLE conversation_migration_map (
      tenant_id uuid NOT NULL, old_id text NOT NULL, id uuid NOT NULL,
      PRIMARY KEY (tenant_id, old_id)
    ) ON COMMIT DROP;
    CREATE TEMP TABLE message_migration_map (
      tenant_id uuid NOT NULL, old_id text NOT NULL, id uuid NOT NULL,
      old_conversation_id text NOT NULL, conversation_id uuid NOT NULL,
      provider_message_id text NOT NULL, seq bigint NOT NULL,
      PRIMARY KEY (tenant_id, old_id), UNIQUE (tenant_id, old_conversation_id, provider_message_id)
    ) ON COMMIT DROP;
    """)
  end

  defp prepare_maps(repo) do
    %{rows: channels} =
      query!(repo, "SELECT tenant_id,id FROM signal_gateway_channels ORDER BY tenant_id,id")

    rows = for [tenant, old_id] <- channels, do: [tenant, old_id, uuid()]
    insert_batches(repo, "conversation_migration_map", ~w(tenant_id old_id id), rows)

    %{rows: entries} =
      query!(repo, """
      SELECT e.tenant_id,e.document_id,e.signal_channel_id,m.id,e.source_entry_id,
        row_number() OVER (PARTITION BY e.tenant_id,e.signal_channel_id ORDER BY e.first_seen_at,e.source_entry_id,e.document_id)
      FROM signal_gateway_entries e JOIN conversation_migration_map m ON m.tenant_id=e.tenant_id AND m.old_id=e.signal_channel_id
      ORDER BY e.tenant_id,e.signal_channel_id,e.first_seen_at,e.source_entry_id,e.document_id
      """)

    rows =
      for [tenant, old_id, old_conversation_id, conversation_id, provider_id, seq] <- entries,
          do: [tenant, old_id, uuid(), old_conversation_id, conversation_id, provider_id, seq]

    insert_batches(
      repo,
      "message_migration_map",
      ~w(tenant_id old_id id old_conversation_id conversation_id provider_message_id seq),
      rows
    )

    sql(repo, "ANALYZE conversation_migration_map; ANALYZE message_migration_map")
  end

  # Names and columns are migration-owned constants. UUIDv7 generation stays in
  # Elixir; only round trips are batched (1,000 rows, except the last batch).
  defp insert_batches(repo, table, columns, rows) do
    width = length(columns)

    rows
    |> Enum.chunk_every(1_000)
    |> Enum.each(fn batch ->
      values =
        batch
        |> Enum.with_index()
        |> Enum.map_join(",", fn {_row, index} ->
          "(" <> Enum.map_join(1..width, ",", &"$#{index * width + &1}") <> ")"
        end)

      query!(
        repo,
        "INSERT INTO #{table} (#{Enum.join(columns, ",")}) VALUES #{values}",
        List.flatten(batch)
      )
    end)
  end

  # One statement per call: the Repo log then shows the time of each copy.
  defp copy_public_records(repo) do
    sql(repo, """
    INSERT INTO conversations(tenant_id,id,kind,title,last_activity_at,
      provider_conversation_id,external_kind,reply_mode,visibility,principal_group_id,metadata,raw_payload,
      first_seen_at,last_seen_at,ambient_standing_orders,ambient_standing_orders_set_by,
      ambient_standing_orders_updated_at,inserted_at,updated_at)
    SELECT c.tenant_id,m.id,'external',COALESCE(NULLIF(btrim(c.name),''),c.id),c.last_seen_at,
      c.id,c.kind,c.reply_mode,c.visibility,c.principal_group_id,c.metadata,c.raw_payload,c.first_seen_at,c.last_seen_at,
      c.ambient_standing_orders,c.ambient_standing_orders_set_by,c.ambient_standing_orders_updated_at,
      c.inserted_at,c.updated_at FROM signal_gateway_channels c JOIN conversation_migration_map m ON m.tenant_id=c.tenant_id AND m.old_id=c.id
    """)

    sql(repo, """
    INSERT INTO conversation_participants(tenant_id,conversation_id,principal_uid,role)
      SELECT DISTINCT m.tenant_id,m.id,record.agent_uid,'agent' FROM conversation_migration_map m
      JOIN (
        SELECT tenant_id,signal_channel_id AS old_id,agent_uid FROM signals
        UNION SELECT tenant_id,substring(session_id FROM 16),agent_uid FROM sessions WHERE starts_with(session_id,'signal-channel:')
        UNION SELECT tenant_id,signal_channel_id,agent_uid FROM signal_gateway_outbox_entries
      ) record ON record.tenant_id=m.tenant_id AND record.old_id=m.old_id
      JOIN principals p ON p.tenant_id=record.tenant_id AND p.uid=record.agent_uid AND p.type='agent'
    """)

    sql(repo, """
    INSERT INTO conversation_participants(tenant_id,conversation_id,principal_uid,role)
      SELECT DISTINCT c.tenant_id,c.id,member.principal_uid,'member'
      FROM conversations c JOIN principal_group_memberships member ON member.tenant_id=c.tenant_id AND member.group_id=c.principal_group_id
      JOIN principals p ON p.tenant_id=member.tenant_id AND p.uid=member.principal_uid
      WHERE c.kind='external' AND p.type='human' ON CONFLICT DO NOTHING
    """)

    sql(repo, """
    INSERT INTO conversation_participants(tenant_id,conversation_id,principal_uid,role)
      SELECT c.tenant_id,c.id,p.uid,'member' FROM conversations c
      JOIN principals p ON p.tenant_id=c.tenant_id AND p.uid=c.metadata->>'dm_peer_principal_uid'
      WHERE c.kind='external' AND c.external_kind='im_dm' AND p.type='human' ON CONFLICT DO NOTHING
    """)

    sql(repo, """
    INSERT INTO conversation_messages(tenant_id,id,conversation_id,seq,author_type,author_uid,kind,text,
      attachments,links,mentions,rich_content,origin,created_at)
    SELECT e.tenant_id,m.id,m.conversation_id,m.seq,COALESCE(p.type::text,'unknown'),p.uid,'message',e.text,
      e.attachments,e.links,e.mentions,e.rich_content,'external',COALESCE(e.provider_time,e.first_seen_at)
    FROM signal_gateway_entries e JOIN message_migration_map m ON m.tenant_id=e.tenant_id AND m.old_id=e.document_id
    LEFT JOIN principals p ON p.tenant_id=e.tenant_id AND p.uid=COALESCE(e.author->>'principal_uid',e.author->>'agent_uid')
    """)

    sql(repo, """
    INSERT INTO external_message_refs(tenant_id,message_id,conversation_id,provider_message_id,
      reply_to_provider_message_id,provider_thread_id,author,metadata,raw_payload,provider_time,
      reactions,raw_reaction_keys,content_hash,first_seen_at,last_seen_at,ai_message_id)
    SELECT e.tenant_id,m.id,m.conversation_id,e.source_entry_id,e.reply_to_source_entry_id,e.provider_thread_id,
      e.author,e.metadata,e.raw_payload,e.provider_time,e.reactions,e.raw_reaction_keys,e.content_hash,
      e.first_seen_at,e.last_seen_at,e.ai_message_id FROM signal_gateway_entries e
      JOIN message_migration_map m ON m.tenant_id=e.tenant_id AND m.old_id=e.document_id
    """)

    sql(repo, """
    UPDATE conversation_messages msg SET reply_to_message_id=target.id FROM external_message_refs ref
      JOIN message_migration_map target ON target.tenant_id=ref.tenant_id AND target.conversation_id=ref.conversation_id
        AND target.provider_message_id=ref.reply_to_provider_message_id
      WHERE msg.tenant_id=ref.tenant_id AND msg.id=ref.message_id
    """)

    sql(repo, """
    UPDATE signals s SET message_id=m.id FROM message_migration_map m
      WHERE s.tenant_id=m.tenant_id AND s.signal_channel_id=m.old_conversation_id AND s.source_entry_id=m.provider_message_id
    """)

    sql(repo, """
    UPDATE conversation_messages msg SET session_id=s.session_id,signal_id=s.id
      FROM (SELECT ref.tenant_id,ref.message_id,
          CASE WHEN ai.metadata->'request_metadata'->>'signal_id' ~* #{@uuid_pattern}
            THEN (ai.metadata->'request_metadata'->>'signal_id')::uuid END AS signal_id
        FROM external_message_refs ref JOIN ai_gateway_messages ai ON ai.tenant_id=ref.tenant_id AND ai.id=ref.ai_message_id) origin
      JOIN signals s ON s.tenant_id=origin.tenant_id AND s.id=origin.signal_id
      WHERE msg.tenant_id=origin.tenant_id AND msg.id=origin.message_id AND msg.author_type='agent'
    """)

    sql(repo, """
    UPDATE conversations c SET sequence_high_water=COALESCE((SELECT max(seq) FROM conversation_messages m
      WHERE m.tenant_id=c.tenant_id AND m.conversation_id=c.id),0)
    """)
  end

  defp migrate_columns(repo) do
    # Replace foreign keys before converting their key type. Provider-message IDs
    # stay adapter data; columns that represent public message references become UUIDs.
    %{rows: columns} =
      query!(repo, """
      SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public'
        AND column_name IN ('signal_channel_id','signal_gateway_channel_id')
        AND table_name NOT IN ('signal_gateway_channels','signal_gateway_entries') ORDER BY table_name
      """)

    for [table, column] <- columns do
      drop_column_constraints(repo, table, column)
      sql(repo, "ALTER TABLE #{table} ADD COLUMN conversation_id uuid")

      sql(
        repo,
        "UPDATE #{table} t SET conversation_id=m.id FROM conversation_migration_map m WHERE t.tenant_id=m.tenant_id AND t.#{column}=m.old_id"
      )

      sql(repo, "ALTER TABLE #{table} DROP COLUMN #{column} CASCADE")

      deletion =
        if table in [
             "signal_gateway_inbound_batches",
             "signal_gateway_input_tombstones",
             "signal_gateway_ambient_judgments",
             "brain_claims"
           ], do: "CASCADE", else: "SET NULL (conversation_id)"

      sql(
        repo,
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_conversation_id_fkey FOREIGN KEY (tenant_id,conversation_id) REFERENCES conversations(tenant_id,id) ON DELETE #{deletion}"
      )
    end

    convert_message_column(
      repo,
      "signals",
      "ambient_asked_source_entry_id",
      "ambient_asked_message_id"
    )

    convert_message_column(repo, "agent_files", "source_entry_id", "message_id")

    convert_message_column(
      repo,
      "signal_gateway_ambient_judgments",
      "asked_by_source_entry_id",
      "asked_by_message_id",
      false
    )

    sql(repo, """
    UPDATE signal_gateway_ambient_judgments SET asked_by_state='degraded'
      WHERE asked_by_state='accepted' AND asked_by_message_id IS NULL;
    UPDATE signal_gateway_ambient_judgments SET asked_by_message_id=NULL
      WHERE asked_by_state IS DISTINCT FROM 'accepted';
    """)

    rename_if_present(repo, "signals", "source_entry_id", "provider_message_id")

    rename_if_present(
      repo,
      "signals",
      "reply_preview_source_entry_id",
      "reply_preview_provider_message_id"
    )

    for table <- [
          "scheduled_events",
          "signal_gateway_webhook_endpoints",
          "signal_gateway_input_tombstones",
          "automation_jobs"
        ] do
      rename_if_present(repo, table, "source_entry_id", "provider_message_id")
    end

    for {old, new} <- [
          {"reply_to_source_entry_id", "reply_to_provider_message_id"},
          {"target_source_entry_id", "target_provider_message_id"},
          {"created_source_entry_id", "created_provider_message_id"}
        ] do
      rename_if_present(repo, "signal_gateway_outbox_entries", old, new)
    end

    rename_if_present(
      repo,
      "signal_gateway_inbound_batches",
      "reply_to_source_entry_id",
      "reply_to_provider_message_id"
    )
  end

  defp migrate_session_keys(repo) do
    sql(repo, """
    UPDATE sessions s SET conversation_id=m.id,session_id='conversation:'||m.id::text
      FROM conversation_migration_map m WHERE s.tenant_id=m.tenant_id AND s.session_id='signal-channel:'||m.old_id;
    """)

    %{rows: columns} =
      query!(repo, """
      SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public'
        AND data_type='text' AND column_name IN ('session_id','owner_session_id','conversation_key','provenance_session')
        AND table_name<>'sessions'
      """)

    for [table, column] <- columns do
      sql(
        repo,
        "UPDATE #{table} t SET #{column}='conversation:'||m.id::text FROM conversation_migration_map m WHERE t.tenant_id=m.tenant_id AND t.#{column}='signal-channel:'||m.old_id"
      )
    end
  end

  defp migrate_brain(repo) do
    sql(repo, "ALTER TABLE brain_sources ADD COLUMN extracted_through_seq bigint")

    sql(repo, """
    UPDATE brain_sources s SET extracted_through_seq=COALESCE((SELECT max(m.seq)
      FROM message_migration_map m JOIN signal_gateway_entries e ON e.tenant_id=m.tenant_id AND e.document_id=m.old_id
      WHERE m.tenant_id=s.tenant_id AND m.old_conversation_id=s.upstream_id AND
        (e.first_seen_at<s.extracted_through_at OR (e.first_seen_at=s.extracted_through_at AND e.source_entry_id<=s.extracted_through_entry_id))),0)
      WHERE s.kind='signal_channel' AND s.extracted_through_at IS NOT NULL;
    UPDATE brain_sources s SET kind='conversation',upstream_id=m.id::text
      FROM conversation_migration_map m WHERE s.tenant_id=m.tenant_id AND s.kind='signal_channel' AND s.upstream_id=m.old_id;
    ALTER TABLE brain_sources DROP COLUMN extracted_through_entry_id;
    """)

    %{rows: [[shape]]} =
      query!(repo, """
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid='brain_claims'::regclass AND conname='brain_claims_type_shape'
      """)

    source_shape = String.replace(shape, ", provenance_session", "")

    if source_shape == shape,
      do: raise(Ecto.MigrationError, message: "missing Take provenance_session shape constraint")

    sql(repo, "ALTER TABLE brain_claims DROP CONSTRAINT brain_claims_type_shape")
    sql(repo, "ALTER TABLE brain_claims ADD CONSTRAINT brain_claims_type_shape #{source_shape}")
  end

  defp migrate_files(repo) do
    sql(
      repo,
      "CREATE TEMP TABLE file_migration_map (tenant_id uuid,agent_uid text,old_path text,new_path text) ON COMMIT DROP"
    )

    %{rows: files} =
      query!(repo, """
      SELECT f.tenant_id,f.agent_uid,f.path,m.old_id,m.id FROM agent_files f
        JOIN conversation_migration_map m ON m.tenant_id=f.tenant_id AND m.id=f.conversation_id
      """)

    rows =
      Enum.flat_map(files, fn [tenant, agent, path, old_id, id] ->
        segment = URI.encode(old_id, &(&1 == ?: or URI.char_unreserved?(&1)))

        segment =
          if segment in [".", ".."], do: String.replace(segment, ".", "%2E"), else: segment

        old_prefix = "chats/#{segment}/"

        if String.starts_with?(path, old_prefix) do
          new_path =
            "chats/#{Ecto.UUID.load!(id)}/" <> String.replace_prefix(path, old_prefix, "")

          [[tenant, agent, path, new_path]]
        else
          []
        end
      end)

    insert_batches(repo, "file_migration_map", ~w(tenant_id agent_uid old_path new_path), rows)

    %{rows: conflicts} =
      query!(repo, """
      SELECT m.new_path FROM file_migration_map m JOIN agent_files f
        ON f.tenant_id=m.tenant_id AND f.agent_uid=m.agent_uid AND f.path<>m.old_path
        AND (f.path=m.new_path OR starts_with(f.path,m.new_path||'/') OR starts_with(m.new_path,f.path||'/'))
      ORDER BY m.new_path LIMIT 1
      """)

    if conflicts != [],
      do:
        raise(Ecto.MigrationError,
          message: "conversation file path conflict: #{hd(hd(conflicts))}"
        )

    sql(
      repo,
      "UPDATE agent_files f SET path=m.new_path FROM file_migration_map m WHERE f.tenant_id=m.tenant_id AND f.agent_uid=m.agent_uid AND f.path=m.old_path"
    )
  end

  defp migrate_typed_json(repo) do
    sql(repo, """
    CREATE FUNCTION pg_temp.conversation_references(value jsonb, tenant uuid, old_conversation text DEFAULT NULL)
    RETURNS jsonb LANGUAGE plpgsql AS $$
    DECLARE result jsonb; key text; item jsonb; mapped text; current_conversation text;
    BEGIN
      IF value IS NULL THEN RETURN NULL; END IF;
      IF jsonb_typeof(value)='object' THEN
        current_conversation:=COALESCE(value->>'signal_channel_id',value->>'channel_id',old_conversation);
        result:='{}'::jsonb;
        FOR key,item IN SELECT * FROM jsonb_each(value) LOOP
          IF key IN ('raw_payload','provider_payload') THEN result:=result||jsonb_build_object(key,item); CONTINUE; END IF;
          IF key IN ('signal_channel_id','channel_id') AND jsonb_typeof(item)='string' THEN
            SELECT id::text INTO mapped FROM conversation_migration_map WHERE tenant_id=tenant AND old_id=item#>>'{}';
            IF mapped IS NOT NULL THEN result:=result||jsonb_build_object('conversation_id',mapped); CONTINUE; END IF;
          ELSIF key='document_id' AND jsonb_typeof(item)='string' THEN
            SELECT id::text INTO mapped FROM message_migration_map WHERE tenant_id=tenant AND old_id=item#>>'{}';
            IF mapped IS NOT NULL THEN result:=result||jsonb_build_object('message_id',mapped); CONTINUE; END IF;
          ELSIF key='source_entry_id' AND jsonb_typeof(item)='string' THEN
            SELECT id::text INTO mapped FROM message_migration_map WHERE tenant_id=tenant
              AND old_conversation_id=current_conversation AND provider_message_id=item#>>'{}';
            result:=result||jsonb_build_object('provider_message_id',item);
            IF mapped IS NOT NULL THEN result:=result||jsonb_build_object('message_id',mapped); END IF;
            CONTINUE;
          ELSIF key='reply_to_source_entry_id' THEN
            result:=result||jsonb_build_object('reply_to_provider_message_id',item); CONTINUE;
          ELSIF key='path' AND jsonb_typeof(item)='string' THEN
            SELECT new_path INTO mapped FROM file_migration_map WHERE tenant_id=tenant AND old_path=item#>>'{}' LIMIT 1;
            IF mapped IS NOT NULL THEN result:=result||jsonb_build_object(key,mapped); CONTINUE; END IF;
          ELSIF key IN ('session_id','owner_session_id','conversation_key') AND jsonb_typeof(item)='string' THEN
            SELECT 'conversation:'||id::text INTO mapped FROM conversation_migration_map WHERE tenant_id=tenant AND 'signal-channel:'||old_id=item#>>'{}';
            IF mapped IS NOT NULL THEN result:=result||jsonb_build_object(key,mapped); CONTINUE; END IF;
          END IF;
          result:=result||jsonb_build_object(key,pg_temp.conversation_references(item,tenant,current_conversation));
        END LOOP;
        RETURN result;
      ELSIF jsonb_typeof(value)='array' THEN
        SELECT COALESCE(jsonb_agg(pg_temp.conversation_references(element,tenant,old_conversation) ORDER BY ordinal),'[]'::jsonb)
          INTO result FROM jsonb_array_elements(value) WITH ORDINALITY arr(element,ordinal);
        RETURN result;
      END IF;
      RETURN value;
    END $$;
    """)

    %{rows: columns} =
      query!(repo, """
      SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public' AND data_type='jsonb'
        AND column_name IN ('data','entries','source_provenance','reply_route','request_context','runtime_projection','wake_payload','payload','recovery_state','config')
        AND table_name NOT IN ('ai_gateway_messages','external_message_refs','signal_gateway_channels','signal_gateway_entries','ai_gateway_compaction_artifacts')
        AND EXISTS(SELECT 1 FROM information_schema.columns t WHERE t.table_schema='public' AND t.table_name=information_schema.columns.table_name AND t.column_name='tenant_id')
      """)

    for [table, column] <- columns do
      scope =
        if table == "signals" and column == "data",
          do:
            " AND (type LIKE 'im.%' OR type LIKE 'command.%' OR type LIKE 'conversation.%' OR type IN ('signal.action.invoked','webhook.received'))",
          else: ""

      sql(
        repo,
        "UPDATE #{table} SET #{column}=pg_temp.conversation_references(#{column},tenant_id) WHERE #{column} IS NOT NULL#{scope}"
      )
    end

    sql(repo, """
    UPDATE ai_gateway_messages SET metadata=jsonb_set(metadata,'{request_metadata}',
      pg_temp.conversation_references(metadata->'request_metadata',tenant_id)) WHERE metadata?'request_metadata'
    """)

    sql(repo, """
    UPDATE ai_gateway_conversations SET metadata=jsonb_set(metadata,'{origin}',
      pg_temp.conversation_references(metadata->'origin',tenant_id)) WHERE metadata?'origin'
    """)

    mark_conversation_reads(repo)

    sql(repo, """
    UPDATE conversation_messages SET attachments=ARRAY(SELECT pg_temp.conversation_references(a,tenant_id) FROM unnest(attachments) a)
    """)
  end

  # Each AI message that came from an external conversation records which
  # message sequence it had read. The signal references are collected once per
  # message and joined by uuid, so every lookup uses the primary keys.
  defp mark_conversation_reads(repo) do
    sql(repo, """
    CREATE TEMP TABLE ai_conversation_reads ON COMMIT DROP AS
    SELECT ai.tenant_id,ai.id AS message_id,map.id AS conversation_id,
      CASE WHEN ref.signal_id ~* #{@uuid_pattern} THEN ref.signal_id::uuid END AS signal_id
    FROM ai_gateway_messages ai
    JOIN ai_gateway_conversations c ON c.tenant_id=ai.tenant_id AND c.id=ai.conversation_id
    JOIN conversation_migration_map map ON map.tenant_id=c.tenant_id AND c.conversation_key='conversation:'||map.id::text
    LEFT JOIN LATERAL (
      SELECT ai.metadata->'request_metadata'->>'signal_id' AS signal_id
      UNION ALL
      SELECT item->>'signal_id' FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(ai.metadata->'request_metadata'->'request_refs')='array'
          THEN ai.metadata->'request_metadata'->'request_refs' ELSE '[]'::jsonb END) item
    ) ref ON true
    WHERE ai.metadata?'request_metadata' AND NOT (ai.metadata->'request_metadata'?'conversation_read')
    """)

    sql(repo, "ANALYZE ai_conversation_reads")

    sql(repo, """
    CREATE TEMP TABLE ai_conversation_read_marks ON COMMIT DROP AS
    SELECT r.tenant_id,r.message_id,r.conversation_id,COALESCE(max(msg.seq),0) AS max_seq
    FROM ai_conversation_reads r
    LEFT JOIN signals s ON s.tenant_id=r.tenant_id AND s.id=r.signal_id
    LEFT JOIN LATERAL (
      SELECT s.message_id AS id UNION ALL
      SELECT CASE WHEN item#>>'{}' ~* #{@uuid_pattern} THEN (item#>>'{}')::uuid END
        FROM jsonb_path_query(s.data,'$.**.message_id') item
    ) refs ON true
    LEFT JOIN conversation_messages msg ON msg.tenant_id=r.tenant_id
      AND msg.conversation_id=r.conversation_id AND msg.id=refs.id
    GROUP BY r.tenant_id,r.message_id,r.conversation_id
    """)

    sql(repo, "ANALYZE ai_conversation_read_marks")

    sql(repo, """
    UPDATE ai_gateway_messages ai SET metadata=jsonb_set(ai.metadata,'{request_metadata,conversation_read}',
      jsonb_build_object('id',mark.conversation_id::text,'max_seq',mark.max_seq))
    FROM ai_conversation_read_marks mark WHERE ai.tenant_id=mark.tenant_id AND ai.id=mark.message_id
    """)
  end

  defp retire_old_records(repo) do
    sql(repo, """
    DO $$ BEGIN
      IF (SELECT count(*) FROM signal_gateway_channels)<>(SELECT count(*) FROM conversation_migration_map) OR
         (SELECT count(*) FROM signal_gateway_entries)<>(SELECT count(*) FROM message_migration_map) THEN
        RAISE EXCEPTION 'external conversation/message migration count mismatch';
      END IF;
    END $$;
    DROP TABLE signal_gateway_entries;
    DROP TABLE signal_gateway_channels;
    """)
  end

  defp migrate_jobs(repo) do
    sql(repo, """
    UPDATE oban_jobs SET args=pg_temp.conversation_references(args,(args->>'tenant_id')::uuid)
      WHERE args->>'tenant_id' ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$';
    """)

    for {old, new} <- [
          {"Ankole.SignalsGateway.Jobs.OutboxDispatch",
           "Ankole.Conversations.Delivery.Jobs.Dispatch"},
          {"Ankole.SignalsGateway.Jobs.ReplyPreviewCheckpoint",
           "Ankole.Conversations.Delivery.Jobs.PreviewCheckpoint"},
          {"Ankole.SignalsGateway.Jobs.ReplyPreviewCleanup",
           "Ankole.Conversations.Delivery.Jobs.PreviewCleanup"},
          {"Ankole.SignalsGateway.Jobs.CleanupExpiredState",
           "Ankole.Signals.Jobs.CleanupExpiredState"},
          {"Ankole.SignalsGateway.Jobs.InboundBatchFinalize",
           "Ankole.Conversations.Jobs.InboundBatchFinalize"},
          {"Ankole.Brain.Jobs.ProcessChannelSlice", "Ankole.Brain.Jobs.ProcessConversationSlice"}
        ] do
      query!(repo, "UPDATE oban_jobs SET worker=$2 WHERE worker=$1", [old, new])
    end
  end

  defp migrate_signal_configuration(repo) do
    sql(repo, """
    DO $$ BEGIN
      IF to_regclass('public.sessions_actor_index') IS NOT NULL THEN
        ALTER INDEX sessions_actor_index RENAME TO sessions_session_index;
      END IF;
      IF to_regclass('public.sessions_session_index') IS NULL THEN
        RAISE EXCEPTION 'Missing canonical Session identity index';
      END IF;
    END $$;
    """)

    for {table, tenant_column} <- [
          {"site_app_configurations", "NULL::uuid"},
          {"app_configurations", "tenant_id"}
        ] do
      %{rows: rows} =
        query!(repo, """
        SELECT #{tenant_column},scope,key,value FROM #{table}
        WHERE left(key,length('signals_gateway.'))='signals_gateway.'
        ORDER BY scope,key FOR UPDATE
        """)

      for [tenant, scope, old_key, envelope] <- rows do
        key = String.replace_prefix(old_key, "signals_gateway.", "signals.")
        tenant_scope = if tenant, do: " AND tenant_id=$4", else: ""
        identity = [scope, key] ++ if(tenant, do: [tenant], else: [])
        collision_scope = if tenant, do: " AND tenant_id=$3", else: ""

        if query!(
             repo,
             "SELECT 1 FROM #{table} WHERE scope=$1 AND key=$2#{collision_scope}",
             identity
           ).num_rows > 0 do
          raise Ecto.MigrationError,
            message: "Signal configuration key conflict in #{table}: #{scope}/#{key}"
        end

        envelope = rekey_config_envelope(envelope, scope, old_key, key)
        params = [key, envelope, scope] ++ if(tenant, do: [tenant], else: [])
        old_key_param = length(params) + 1

        query!(
          repo,
          "UPDATE #{table} SET key=$1,value=$2 WHERE scope=$3#{tenant_scope} AND key=$#{old_key_param}",
          params ++ [old_key]
        )
      end
    end

    sql(repo, """
    UPDATE signal_bindings SET config_ref='app-config://signals.'||substring(config_ref FROM length('app-config://signals_gateway.')+1)
      WHERE left(config_ref,length('app-config://signals_gateway.'))='app-config://signals_gateway.';
    DO $$ BEGIN
      IF EXISTS(SELECT 1 FROM principal_groups WHERE domain IN ('signal_source','im_group') AND metadata?'signals_gateway' AND metadata?'signals') THEN
        RAISE EXCEPTION 'Signal group metadata conflict: both namespace roots exist';
      END IF;
    END $$;
    UPDATE principal_groups SET metadata=(metadata-'signals_gateway')||jsonb_build_object('signals',metadata->'signals_gateway')
      WHERE domain IN ('signal_source','im_group') AND metadata?'signals_gateway';
    UPDATE signals SET data=jsonb_set(data,'{metadata}',
      ((data->'metadata')-'source_signal_gateway_entries')||jsonb_build_object('source_messages',
        COALESCE((SELECT jsonb_agg(item||jsonb_build_object('message_id',m.id::text) ORDER BY ordinal)
          FROM jsonb_array_elements(data->'metadata'->'source_signal_gateway_entries') WITH ORDINALITY e(item,ordinal)
          JOIN message_migration_map m ON m.tenant_id=signals.tenant_id AND m.conversation_id=signals.conversation_id
            AND m.provider_message_id=item->>'provider_message_id'),'[]'::jsonb)))
      WHERE type IN ('conversation.message.addressed','im.message.may_intervene')
        AND jsonb_typeof(data->'metadata'->'source_signal_gateway_entries')='array';
    """)

    sql(repo, """
    UPDATE deliveries SET payload=jsonb_set(payload,'{metadata,source}',
      to_jsonb('session_'||substring(payload->'metadata'->>'source' FROM length('actor_')+1)))
      WHERE delivery_class='durable_ai_reply'
        AND payload->'metadata'->>'source' IN (
          'actor_dead_letter_notice','actor_turn_stopped','actor_model_profile_unavailable_notice',
          'actor_token_quota_exceeded_notice','actor_tenant_suspended_notice');
    """)

    migrate_console_grants(repo)
  end

  defp rekey_config_envelope(
         %{"type" => "cipher", "value" => ciphertext} = envelope,
         scope,
         old,
         key
       ) do
    with {:ok, value} <- Ankole.AppConfigure.Crypto.unseal(ciphertext, scope, old),
         {:ok, ciphertext} <- Ankole.AppConfigure.Crypto.seal(value, scope, key) do
      Map.put(envelope, "value", ciphertext)
    else
      _ ->
        raise Ecto.MigrationError,
          message: "Cannot rekey encrypted Signal configuration: #{scope}/#{old}"
    end
  end

  defp rekey_config_envelope(%{"type" => "plaintext"} = envelope, _scope, _old, _key),
    do: envelope

  defp rekey_config_envelope(_envelope, scope, old, _key) do
    raise Ecto.MigrationError, message: "Invalid Signal configuration envelope: #{scope}/#{old}"
  end

  defp migrate_console_grants(repo) do
    %{rows: rows} =
      query!(repo, """
      SELECT tenant_id,id,resource_pattern,condition FROM permission_grants
      WHERE position('signal_gateway_' IN resource_pattern)>0
      ORDER BY tenant_id,id FOR UPDATE
      """)

    for [tenant, id, pattern, condition] <- rows do
      pattern =
        pattern
        |> String.replace("signal_gateway_adapters", "signals_adapters")
        |> String.replace("signal_gateway_channels", "conversations")
        |> then(fn pattern ->
          Regex.replace(~r/signal_gateway_[^,{}]+/, pattern, fn branch ->
            targets =
              for {old, new} <- [
                    {"signal_gateway_adapters", "signals_adapters"},
                    {"signal_gateway_channels", "conversations"}
                  ],
                  Ankole.Kernel.authz_match_resource_pattern(branch, old) == true,
                  do: new

            case targets do
              [target] ->
                target

              [first, second] ->
                if String.contains?(pattern, "{"),
                  do: "#{first},#{second}",
                  else: "{#{first},#{second}}"

              [] ->
                raise Ecto.MigrationError,
                  message:
                    "Unmapped Console resource in permission grant #{Ecto.UUID.load!(id)}: #{branch}"
            end
          end)
        end)

      if Ankole.Kernel.authz_validate_resource_pattern(pattern) != true do
        raise Ecto.MigrationError,
          message: "Invalid migrated Console resource in permission grant #{Ecto.UUID.load!(id)}"
      end

      condition =
        condition
        |> String.replace("signal_gateway_adapters", "signals_adapters")
        |> String.replace("signal_gateway_channels", "conversations")

      query!(
        repo,
        "UPDATE permission_grants SET resource_pattern=$1,condition=$2 WHERE tenant_id=$3 AND id=$4",
        [pattern, condition, tenant, id]
      )
    end
  end

  defp migrate_addressed_signals(repo) do
    sql(repo, """
    UPDATE signals s SET type='conversation.message.addressed',
      data=(COALESCE(s.data,'{}'::jsonb)-'channel_context')||jsonb_build_object(
        'conversation_id',s.conversation_id::text,'message_id',s.message_id::text,
        'text',COALESCE(s.data->>'text',s.data->'entry'->>'text',
          (SELECT string_agg(item->>'text',E'\\n' ORDER BY ordinal)
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.data->'entries')='array' THEN s.data->'entries' ELSE '[]'::jsonb END)
              WITH ORDINALITY e(item,ordinal))),
        'message_ids',COALESCE((SELECT jsonb_agg(DISTINCT id) FROM (
          SELECT s.message_id::text AS id UNION ALL SELECT s.data->'entry'->>'message_id'
          UNION ALL SELECT item->>'message_id' FROM jsonb_array_elements(
            CASE WHEN jsonb_typeof(s.data->'entries')='array' THEN s.data->'entries' ELSE '[]'::jsonb END) item
        ) ids WHERE id IS NOT NULL),'[]'::jsonb))
      WHERE s.type='im.message.addressed' AND s.conversation_id IS NOT NULL;
    """)
  end

  defp rename_tables(repo) do
    for {old, new} <- @renames, do: sql(repo, "ALTER TABLE #{old} RENAME TO #{new}")

    sql(
      repo,
      "ALTER SEQUENCE signal_gateway_attachment_id_seq RENAME TO conversation_attachment_id_seq"
    )

    %{rows: constraints} =
      query!(
        repo,
        "SELECT conrelid::regclass::text,conname FROM pg_constraint WHERE connamespace='public'::regnamespace AND conname LIKE 'signal_gateway_%'"
      )

    for [table, name] <- constraints do
      renamed = renamed(name)

      if renamed != name,
        do: sql(repo, "ALTER TABLE #{table} RENAME CONSTRAINT #{name} TO #{renamed}")
    end

    %{rows: indexes} =
      query!(
        repo,
        "SELECT indexname FROM pg_indexes WHERE schemaname='public' AND indexname LIKE 'signal_gateway_%'"
      )

    for [name] <- indexes do
      renamed = renamed(name)
      if renamed != name, do: sql(repo, "ALTER INDEX #{name} RENAME TO #{renamed}")
    end
  end

  defp finish_constraints(repo) do
    sql(repo, """
    CREATE UNIQUE INDEX signal_bindings_tenant_route_index ON signal_bindings(tenant_id,agent_uid,name);
    CREATE UNIQUE INDEX principal_groups_tenant_identity_index ON principal_groups(tenant_id,id);
    ALTER TABLE conversations ADD CONSTRAINT conversations_kind_check CHECK (kind IN ('native','external'));
    ALTER TABLE conversations ADD CONSTRAINT conversations_origin_check CHECK (
      (kind='native' AND created_by IS NOT NULL AND provider_conversation_id IS NULL) OR
      (kind='external' AND provider_conversation_id IS NOT NULL AND btrim(provider_conversation_id)<>'' AND external_kind IS NOT NULL AND reply_mode IS NOT NULL));
    ALTER TABLE conversations ADD CONSTRAINT conversations_principal_group_id_fkey
      FOREIGN KEY (tenant_id,principal_group_id) REFERENCES principal_groups(tenant_id,id) ON DELETE SET NULL (principal_group_id);
    CREATE UNIQUE INDEX conversations_external_identity_index ON conversations(tenant_id,provider_conversation_id) WHERE kind='external';
    CREATE UNIQUE INDEX conversation_messages_signal_index ON conversation_messages(tenant_id,conversation_id,signal_id)
      WHERE signal_id IS NOT NULL AND origin='native';
    ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_author_type_check CHECK (author_type IN ('human','agent','unknown'));
    ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_text_present CHECK (origin='external' OR (text IS NOT NULL AND btrim(text)<>''));
    ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_origin_check CHECK (origin IN ('native','external'));
    ALTER TABLE conversation_messages ADD CONSTRAINT conversation_messages_provenance_check CHECK (
      origin='external' OR (author_uid IS NOT NULL AND ((author_type='human' AND signal_id IS NULL AND session_id IS NULL) OR
      (author_type='agent' AND signal_id IS NOT NULL AND session_id IS NOT NULL AND btrim(session_id)<>''))));
    ALTER TABLE signal_bindings ADD COLUMN target jsonb NOT NULL DEFAULT '{}';
    ALTER TABLE signal_bindings ADD CONSTRAINT signal_bindings_target_object CHECK (jsonb_typeof(target)='object');
    ALTER TABLE signal_webhook_endpoints ADD COLUMN event_format text NOT NULL DEFAULT 'raw';
    ALTER TABLE signal_webhook_endpoints ALTER COLUMN agent_uid DROP NOT NULL;
    ALTER TABLE signal_webhook_endpoints ALTER COLUMN session_id DROP NOT NULL;
    ALTER TABLE signal_webhook_endpoints ADD CONSTRAINT signal_webhook_endpoints_event_format_check CHECK (event_format IN ('raw','cloudevents'));
    ALTER TABLE signal_webhook_endpoints ADD CONSTRAINT signal_webhook_endpoints_raw_target_check CHECK (event_format='cloudevents' OR (agent_uid IS NOT NULL AND session_id IS NOT NULL AND btrim(session_id)<>''));
    ALTER TABLE conversation_input_tombstones ALTER COLUMN conversation_id SET NOT NULL;
    ALTER TABLE conversation_input_tombstones ADD PRIMARY KEY (tenant_id,agent_uid,binding_name,conversation_id,provider_message_id);
    ALTER TABLE conversation_inbound_batches ALTER COLUMN conversation_id SET NOT NULL;
    CREATE UNIQUE INDEX conversation_inbound_batches_open_index ON conversation_inbound_batches
      (tenant_id,agent_uid,binding_name,conversation_id,provider_thread_id) WHERE batch_state='open';
    CREATE INDEX conversation_inbound_batches_message_lookup_index ON conversation_inbound_batches(tenant_id,agent_uid,binding_name,conversation_id);
    CREATE INDEX signals_message_origin_index ON signals(tenant_id,agent_uid,reply_binding_name,conversation_id,provider_message_id);
    CREATE INDEX session_ambient_judgments_conversation_index ON session_ambient_judgments(tenant_id,conversation_id,inserted_at);
    ALTER TABLE session_ambient_judgments ADD CONSTRAINT session_ambient_judgments_asked_by_shape_check CHECK (
      CASE asked_by_state
        WHEN 'accepted' THEN asked_by_message_id IS NOT NULL
        WHEN 'degraded' THEN asked_by_message_id IS NULL
        ELSE asked_by_state IS NULL AND asked_by_message_id IS NULL
      END);
    CREATE INDEX brain_claims_conversation_current_idx ON brain_claims(tenant_id,conversation_id,holder,valid_from DESC)
      WHERE claim_type='fact' AND expired_at IS NULL AND conversation_id IS NOT NULL;
    ALTER TABLE brain_claims ADD CONSTRAINT brain_claims_parent_xor CHECK (num_nonnulls(object_slug,conversation_id)=1);
    """)
  end

  defp migrate_deliveries(repo) do
    %{rows: checks} =
      query!(
        repo,
        "SELECT conname,pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='deliveries'::regclass AND contype='c' AND pg_get_constraintdef(oid) LIKE '%status%'"
      )

    %{rows: indexes} =
      query!(
        repo,
        "SELECT indexname,indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='deliveries' AND indexdef LIKE '%status%'"
      )

    for [name, _] <- checks, do: sql(repo, "ALTER TABLE deliveries DROP CONSTRAINT #{name}")
    for [name, _] <- indexes, do: sql(repo, "DROP INDEX #{name}")

    sql(repo, """
    CREATE TYPE delivery_status AS ENUM ('pending','sent','failed','expired','unknown');
    ALTER TABLE deliveries ALTER COLUMN status DROP DEFAULT;
    UPDATE deliveries SET next_attempt_at=NULL WHERE status::text='unknown_after_send';
    UPDATE deliveries SET last_error=COALESCE(last_error,'{}'::jsonb)||jsonb_build_object('code','unsupported'),
      recovery_state=COALESCE(recovery_state,'{}'::jsonb)||jsonb_build_object('state','permanent') WHERE status::text='unsupported';
    ALTER TABLE deliveries ALTER COLUMN status TYPE delivery_status USING
      (CASE status::text WHEN 'created' THEN 'pending' WHEN 'sending' THEN 'pending'
        WHEN 'succeeded' THEN 'sent' WHEN 'unsupported' THEN 'failed' WHEN 'unknown_after_send' THEN 'unknown'
        ELSE status::text END)::delivery_status;
    ALTER TABLE deliveries ALTER COLUMN status SET DEFAULT 'pending'::delivery_status;
    DROP TYPE signal_gateway_outbox_status;
    ALTER TYPE signal_gateway_outbox_operation RENAME TO delivery_operation;
    ALTER TABLE deliveries ADD COLUMN expires_at timestamp(6) without time zone;
    ALTER TABLE deliveries ADD COLUMN created_message_id uuid;
    ALTER TABLE deliveries ADD COLUMN target_message_id uuid;
    ALTER TABLE deliveries ADD COLUMN reply_to_message_id uuid;
    UPDATE deliveries d SET created_message_id=m.id FROM message_migration_map m
      WHERE d.tenant_id=m.tenant_id AND d.conversation_id=m.conversation_id AND d.created_provider_message_id=m.provider_message_id;
    UPDATE deliveries d SET target_message_id=m.id FROM message_migration_map m
      WHERE d.tenant_id=m.tenant_id AND d.conversation_id=m.conversation_id AND d.target_provider_message_id=m.provider_message_id;
    UPDATE deliveries d SET reply_to_message_id=m.id FROM message_migration_map m
      WHERE d.tenant_id=m.tenant_id AND d.conversation_id=m.conversation_id AND d.reply_to_provider_message_id=m.provider_message_id;
    ALTER TABLE deliveries ADD CONSTRAINT deliveries_created_message_id_fkey FOREIGN KEY (tenant_id,created_message_id) REFERENCES conversation_messages(tenant_id,id) ON DELETE SET NULL (created_message_id);
    ALTER TABLE deliveries ADD CONSTRAINT deliveries_target_message_id_fkey FOREIGN KEY (tenant_id,target_message_id) REFERENCES conversation_messages(tenant_id,id) ON DELETE SET NULL (target_message_id);
    ALTER TABLE deliveries ADD CONSTRAINT deliveries_reply_to_message_id_fkey FOREIGN KEY (tenant_id,reply_to_message_id) REFERENCES conversation_messages(tenant_id,id) ON DELETE SET NULL (reply_to_message_id);
    """)

    for [name, definition] <- checks,
        do:
          sql(
            repo,
            "ALTER TABLE deliveries ADD CONSTRAINT #{name} #{delivery_status_sql(definition)}"
          )

    for [_, definition] <- indexes, do: sql(repo, delivery_status_sql(definition))
  end

  defp delivery_status_sql(definition) do
    Enum.reduce(
      [
        {"'created'", "'pending'"},
        {"'sending'", "'pending'"},
        {"'succeeded'", "'sent'"},
        {"'unsupported'", "'failed'"},
        {"'unknown_after_send'", "'unknown'"},
        {"signal_gateway_outbox_status", "delivery_status"}
      ],
      definition,
      fn {old, new}, acc -> String.replace(acc, old, new) end
    )
  end

  defp convert_message_column(repo, table, old, new, required \\ true) do
    if column?(repo, table, old) do
      sql(repo, "ALTER TABLE #{table} ADD COLUMN #{new} uuid")

      sql(
        repo,
        "UPDATE #{table} t SET #{new}=m.id FROM message_migration_map m JOIN conversation_migration_map c ON c.tenant_id=m.tenant_id AND c.id=m.conversation_id WHERE t.tenant_id=m.tenant_id AND t.conversation_id=c.id AND t.#{old}=m.provider_message_id"
      )

      sql(repo, "ALTER TABLE #{table} DROP COLUMN #{old} CASCADE")

      sql(
        repo,
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_#{new}_fkey FOREIGN KEY (tenant_id,#{new}) REFERENCES conversation_messages(tenant_id,id) ON DELETE SET NULL (#{new})"
      )
    else
      if required,
        do: raise(Ecto.MigrationError, message: "missing migration column: #{table}.#{old}")
    end
  end

  defp drop_column_constraints(repo, table, column) do
    %{rows: rows} =
      query!(
        repo,
        "SELECT conname FROM pg_constraint WHERE conrelid=$1::text::regclass AND contype='f' AND $2=ANY(SELECT attname FROM pg_attribute WHERE attrelid=conrelid AND attnum=ANY(conkey))",
        [table, column]
      )

    for [name] <- rows, do: sql(repo, "ALTER TABLE #{table} DROP CONSTRAINT #{name}")
  end

  defp rename_if_present(repo, table, old, new),
    do:
      if(column?(repo, table, old),
        do: sql(repo, "ALTER TABLE #{table} RENAME COLUMN #{old} TO #{new}")
      )

  defp column?(repo, table, column),
    do:
      query!(
        repo,
        "SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 AND column_name=$2",
        [table, column]
      ).rows != []

  defp renamed(name),
    do: Enum.reduce(@renames, name, fn {old, new}, acc -> String.replace(acc, old, new) end)

  defp uuid, do: Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())

  # Postgrex accepts one prepared statement; migration SQL blocks are simple
  # statements except for PL/pgSQL, which need the simple-query protocol.
  defp sql(repo, statement), do: query!(repo, statement, [], query_type: :text)

  # Data migrations run as long as the site's data needs; the Repo's query
  # timeout is for requests, not for a one-time rewrite inside one transaction.
  defp query!(repo, statement, params \\ [], opts \\ []),
    do: repo.query!(statement, params, Keyword.put(opts, :timeout, :infinity))
end
