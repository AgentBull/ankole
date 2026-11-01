defmodule Ankole.Repo.Migrations.UnifyDriveNodes do
  use Ecto.Migration
  import Bitwise

  @actions ~w(node_view node_contribute node_edit node_manage node_comment)
  @old_actions ~w(page_view page_write_records page_edit page_manage page_comment)
  # Only application-owned attachment slots participate. Text, provider payloads,
  # metadata and recovery checkpoints belong to their producers and stay opaque.
  @json_fields [
    {"ai_gateway_messages", "content", :response_items, "true"},
    {"ai_gateway_compaction_artifacts", "content", :compaction, "true"},
    {"signals", "data", :signal,
     "producer='kernel' AND type IN ('conversation.message.addressed','im.message.may_intervene','input.revised')"},
    {"conversation_inbound_batches", "entries", :messages, "true"}
  ]

  def up, do: execute(&migrate!/0)

  def down do
    raise Ecto.MigrationError,
      message:
        "Drive unification has no automatic rollback. Restore the database and object-store backup."
  end

  defp migrate! do
    Process.put({__MODULE__, :copied_keys}, [])

    try do
      migrate_in_transaction!()
    rescue
      exception ->
        for key <- Process.get({__MODULE__, :copied_keys}, []), do: Ankole.ObjectStore.delete(key)
        reraise exception, __STACKTRACE__
    after
      Process.delete({__MODULE__, :copied_keys})
    end
  end

  defp migrate_in_transaction! do
    # The release must stop writers before this exclusive, one-time conversion.
    # All deletion jobs commit with this migration; no old bytes are deleted here.
    query!(
      "LOCK TABLE pages, drive_files, files, permission_grants, conversation_messages, deliveries IN ACCESS EXCLUSIVE MODE"
    )

    preflight_file_parents!()
    preflight_conditions!()
    agent_file_grants = legacy_agent_file_grants!()
    before = permission_snapshots!("pages", false)
    create_tables!()
    roots = create_roots!()
    migrate_pages!(roots)
    object_map = migrate_objects!()
    migrate_paths!(roots, object_map)
    migrate_attachments!(roots, object_map)
    rewrite_json_references!(object_map)
    migrate_grants!()
    initialize_new_private_grants!()
    finish_nodes!()
    after_snapshots = permission_snapshots!("drive_nodes", true)
    verify_permissions!(before, after_snapshots)
    migrate_agent_file_grants!(agent_file_grants)
    finish_schema!()

    statements!("""
    UPDATE app_configurations SET key='drive.trash_retention_days' WHERE key='pod.trash_retention_days';
    UPDATE oban_jobs SET worker='Ankole.Files.Jobs.PurgeNode',args=(args-'page_id')||jsonb_build_object('node_id',args->'page_id')
      WHERE worker='Ankole.Pod.Jobs.PurgePage' AND args ? 'page_id';
    """)

    enqueue_unreferenced_legacy_objects!()
    query!("DROP TABLE drive_files")
    query!("DROP TABLE files")
  end

  defp create_tables! do
    statements!("""
    CREATE TABLE file_objects (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      storage_key text NOT NULL,
      sha256 bytea,
      size bigint,
      completed_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id,id),
      CONSTRAINT file_objects_completion_shape CHECK (
        (completed_at IS NULL AND sha256 IS NULL AND size IS NULL) OR
        (completed_at IS NOT NULL AND sha256 IS NOT NULL AND octet_length(sha256)=32 AND size IS NOT NULL AND size>=0)
      )
    );
    CREATE UNIQUE INDEX file_objects_storage_key_index ON file_objects(storage_key);
    CREATE INDEX file_objects_collection_index ON file_objects(created_at,tenant_id,id);
    CREATE TABLE drive_nodes (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      parent_id uuid,
      name text NOT NULL,
      kind text NOT NULL,
      private_owner_uid text,
      conversation_id uuid,
      inherit_permissions boolean NOT NULL DEFAULT true,
      has_local_acl boolean NOT NULL DEFAULT false,
      is_acl_anchor boolean GENERATED ALWAYS AS (
        parent_id IS NULL OR NOT inherit_permissions OR has_local_acl OR deleted_at IS NOT NULL
      ) STORED,
      acl_anchor_id uuid,
      parent_anchor_id uuid,
      object_id uuid,
      mode integer NOT NULL DEFAULT 420,
      content_type text,
      source text,
      message_id uuid,
      source_conversation_id uuid,
      created_by text,
      deleted_at timestamptz,
      purge_started_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id,id),
      CONSTRAINT drive_nodes_kind CHECK (kind IN ('folder','file','doc','base','applet')),
      CONSTRAINT drive_nodes_name_shape CHECK (octet_length(name) BETWEEN 1 AND 255 AND name NOT IN ('.','..') AND position('/' in name)=0),
      CONSTRAINT drive_nodes_mode CHECK (mode BETWEEN 0 AND 511),
      CONSTRAINT drive_nodes_object_shape CHECK (object_id IS NULL OR kind='file'),
      CONSTRAINT drive_nodes_root_shape CHECK (
        (parent_id IS NULL AND kind='folder' AND num_nonnulls(private_owner_uid,conversation_id)<=1) OR
        (parent_id IS NOT NULL AND private_owner_uid IS NULL AND conversation_id IS NULL)
      ),
      CONSTRAINT drive_nodes_purge_state CHECK (purge_started_at IS NULL OR deleted_at IS NOT NULL),
      CONSTRAINT drive_nodes_parent_fkey FOREIGN KEY (tenant_id,parent_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
      CONSTRAINT drive_nodes_private_owner_fkey FOREIGN KEY (tenant_id,private_owner_uid) REFERENCES principals(tenant_id,uid) ON DELETE CASCADE,
      CONSTRAINT drive_nodes_conversation_fkey FOREIGN KEY (tenant_id,conversation_id) REFERENCES conversations(tenant_id,id) ON DELETE CASCADE,
      CONSTRAINT drive_nodes_object_fkey FOREIGN KEY (tenant_id,object_id) REFERENCES file_objects(tenant_id,id) ON DELETE RESTRICT,
      CONSTRAINT drive_nodes_message_fkey FOREIGN KEY (tenant_id,message_id) REFERENCES conversation_messages(tenant_id,id) ON DELETE SET NULL (message_id),
      CONSTRAINT drive_nodes_source_conversation_fkey FOREIGN KEY (tenant_id,source_conversation_id) REFERENCES conversations(tenant_id,id) ON DELETE SET NULL (source_conversation_id)
    );
    CREATE UNIQUE INDEX drive_nodes_live_name_index ON drive_nodes(tenant_id,parent_id,name) WHERE deleted_at IS NULL;
    CREATE UNIQUE INDEX drive_nodes_public_root_index ON drive_nodes(tenant_id) WHERE parent_id IS NULL AND private_owner_uid IS NULL AND conversation_id IS NULL;
    CREATE UNIQUE INDEX drive_nodes_private_root_index ON drive_nodes(tenant_id,private_owner_uid) WHERE parent_id IS NULL AND private_owner_uid IS NOT NULL;
    CREATE UNIQUE INDEX drive_nodes_conversation_root_index ON drive_nodes(tenant_id,conversation_id) WHERE parent_id IS NULL AND conversation_id IS NOT NULL;
    CREATE INDEX drive_nodes_object_index ON drive_nodes(tenant_id,object_id) WHERE object_id IS NOT NULL;
    CREATE INDEX drive_nodes_parent_index ON drive_nodes(tenant_id,parent_id) INCLUDE (id,is_acl_anchor);
    CREATE INDEX drive_nodes_live_children_index ON drive_nodes(tenant_id,parent_id,name,id) INCLUDE(kind,acl_anchor_id,inherit_permissions,is_acl_anchor,private_owner_uid) WHERE deleted_at IS NULL;
    CREATE INDEX drive_nodes_acl_anchors_index ON drive_nodes(tenant_id,id) INCLUDE(parent_anchor_id,private_owner_uid,conversation_id,inherit_permissions,deleted_at) WHERE is_acl_anchor;
    CREATE INDEX drive_nodes_acl_anchor_index ON drive_nodes(tenant_id,acl_anchor_id,updated_at DESC,id);
    CREATE INDEX drive_nodes_parent_anchor_index ON drive_nodes(tenant_id,parent_anchor_id) WHERE parent_anchor_id IS NOT NULL;
    CREATE INDEX drive_nodes_name_trgm_index ON drive_nodes USING gin(name gin_trgm_ops) WHERE deleted_at IS NULL AND kind IN ('file','folder');
    CREATE TABLE pod_files (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      node_id uuid,
      path text NOT NULL,
      object_id uuid NOT NULL,
      mode integer NOT NULL DEFAULT 420 CHECK (mode BETWEEN 0 AND 511),
      content_type text NOT NULL,
      source text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id,id),
      CONSTRAINT pod_files_node_fkey FOREIGN KEY (tenant_id,node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE,
      CONSTRAINT pod_files_object_fkey FOREIGN KEY (tenant_id,object_id) REFERENCES file_objects(tenant_id,id) ON DELETE RESTRICT,
      CONSTRAINT pod_files_path_shape CHECK (path<>'' AND path !~ '(^/|/$|//|(^|/)\\.\\.?(/|$))')
    );
    CREATE UNIQUE INDEX pod_files_path_index ON pod_files(tenant_id,node_id,path) NULLS NOT DISTINCT;
    CREATE INDEX pod_files_object_index ON pod_files(tenant_id,object_id);
    CREATE TABLE message_attachments (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      message_id uuid NOT NULL,
      position integer NOT NULL CHECK (position>=0),
      object_id uuid,
      node_id uuid,
      metadata jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(metadata)='object'),
      PRIMARY KEY(tenant_id,message_id,position),
      CONSTRAINT message_attachments_message_fkey FOREIGN KEY(tenant_id,message_id) REFERENCES conversation_messages(tenant_id,id) ON DELETE CASCADE,
      CONSTRAINT message_attachments_object_fkey FOREIGN KEY(tenant_id,object_id) REFERENCES file_objects(tenant_id,id) ON DELETE RESTRICT,
      CONSTRAINT message_attachments_node_fkey FOREIGN KEY(tenant_id,node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE SET NULL (node_id)
    );
    CREATE INDEX message_attachments_object_index ON message_attachments(tenant_id,object_id) WHERE object_id IS NOT NULL;
    CREATE INDEX message_attachments_node_index ON message_attachments(tenant_id,node_id) WHERE node_id IS NOT NULL;
    CREATE UNIQUE INDEX deliveries_tenant_identity_index ON deliveries(tenant_id,agent_uid,binding_name,outbound_key);
    CREATE TABLE delivery_attachments (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      agent_uid text NOT NULL,
      binding_name text NOT NULL,
      outbound_key text NOT NULL,
      position integer NOT NULL CHECK (position>=0),
      object_id uuid,
      node_id uuid,
      metadata jsonb NOT NULL DEFAULT '{}' CHECK(jsonb_typeof(metadata)='object'),
      PRIMARY KEY(tenant_id,agent_uid,binding_name,outbound_key,position),
      CONSTRAINT delivery_attachments_delivery_fkey FOREIGN KEY(tenant_id,agent_uid,binding_name,outbound_key) REFERENCES deliveries(tenant_id,agent_uid,binding_name,outbound_key) ON DELETE CASCADE,
      CONSTRAINT delivery_attachments_object_fkey FOREIGN KEY(tenant_id,object_id) REFERENCES file_objects(tenant_id,id) ON DELETE RESTRICT,
      CONSTRAINT delivery_attachments_node_fkey FOREIGN KEY(tenant_id,node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE SET NULL (node_id)
    );
    CREATE INDEX delivery_attachments_object_index ON delivery_attachments(tenant_id,object_id) WHERE object_id IS NOT NULL;
    CREATE INDEX delivery_attachments_node_index ON delivery_attachments(tenant_id,node_id) WHERE node_id IS NOT NULL;
    """)
  end

  defp create_roots! do
    public =
      for [tenant] <- rows!("SELECT id FROM tenants ORDER BY id"), into: %{} do
        id = insert_node!(tenant, %{name: "public", kind: "folder"})
        {{tenant, :public}, id}
      end

    private =
      for [tenant, uid] <-
            rows!("""
            SELECT tenant_id,uid FROM principals WHERE type='agent' OR (type='human' AND membership='member')
            UNION SELECT tenant_id,private_owner_uid FROM pages WHERE private_owner_uid IS NOT NULL
            UNION SELECT tenant_id,agent_uid FROM drive_files WHERE agent_uid IS NOT NULL
            ORDER BY 1,2
            """),
          into: %{} do
        id = insert_node!(tenant, %{name: "private", kind: "folder", private_owner_uid: uid})
        {{tenant, {:private, uid}}, id}
      end

    conversations =
      for [tenant, conversation] <-
            rows!("SELECT tenant_id,id FROM conversations ORDER BY tenant_id,id"),
          into: %{} do
        id =
          insert_node!(tenant, %{
            name: "conversation",
            kind: "folder",
            conversation_id: conversation
          })

        {{tenant, {:conversation, conversation}}, id}
      end

    public |> Map.merge(private) |> Map.merge(conversations)
  end

  defp migrate_pages!(roots) do
    for page <-
          maps!(
            "SELECT * FROM pages ORDER BY tenant_id,parent_id NULLS FIRST,position COLLATE \"C\",id"
          ) do
      parent =
        page["parent_id"] ||
          Map.fetch!(
            roots,
            {page["tenant_id"],
             if(page["private_owner_uid"],
               do: {:private, page["private_owner_uid"]},
               else: :public
             )}
          )

      name = unique_name!(page["tenant_id"], parent, safe_name(page["title"], page["type"]))
      # Private roots seeded their owner's grants even when inherit_permissions was false.
      # The replacement private folder provides those same bits through inheritance.
      inherit = if page["private_owner_uid"], do: true, else: page["inherit_permissions"]

      insert_node!(page["tenant_id"], %{
        id: page["id"],
        parent_id: parent,
        name: name,
        kind: page["type"],
        inherit_permissions: inherit,
        has_local_acl: page["has_local_acl"],
        created_by: page["created_by"],
        deleted_at: page["deleted_at"],
        purge_started_at: page["purge_started_at"],
        created_at: page["created_at"],
        updated_at: page["updated_at"]
      })
    end
  end

  defp initialize_new_private_grants! do
    # A private root without a legacy Page has no owner grants to migrate.
    # Existing private Page permissions remain subject to the snapshot check.
    for [tenant, uid] <-
          rows!("""
          SELECT n.tenant_id,n.private_owner_uid FROM drive_nodes n
          JOIN principals p ON p.tenant_id=n.tenant_id AND p.uid=n.private_owner_uid
          WHERE n.parent_id IS NULL
            AND (p.type='agent' OR (p.type='human' AND p.membership='member'))
            AND NOT EXISTS (
              SELECT 1 FROM pages old
              WHERE old.tenant_id=n.tenant_id AND old.private_owner_uid=n.private_owner_uid
            )
          """),
        action <- @actions do
      query!(
        "INSERT INTO permission_grants(tenant_id,id,principal_uid,resource_pattern,action,condition,inserted_at,updated_at) VALUES($1,$2,$3,$4,$5,'true',now(),now()) ON CONFLICT DO NOTHING",
        [tenant, uuid(), uid, "drive:private:#{uid}:**", action]
      )
    end
  end

  defp migrate_objects! do
    required = rows!("SELECT DISTINCT tenant_id,encode(sha256,'hex') FROM drive_files")

    required =
      required ++
        rows!(
          "SELECT DISTINCT tenant_id,a->>'blob_ref' FROM conversation_messages CROSS JOIN LATERAL unnest(attachments) a WHERE a->>'blob_ref' IS NOT NULL"
        )

    required =
      required ++
        rows!(
          "SELECT DISTINCT tenant_id,a->>'blob_ref' FROM deliveries CROSS JOIN LATERAL jsonb_array_elements(COALESCE(payload->'attachments','[]')) a WHERE status IN ('pending','failed','unknown') AND a->>'blob_ref' IS NOT NULL"
        )

    optional =
      Enum.flat_map(json_rows(), fn {_table, _column, shape, tenant, _ctid, value} ->
        {_value, hashes} =
          attachment_refs(value, shape, [], fn attachment, hashes ->
            {attachment, [attachment["blob_ref"] | hashes]}
          end)

        Enum.map(hashes, &[tenant, &1])
      end)

    optional =
      optional ++
        rows!(
          "SELECT DISTINCT tenant_id,a->>'blob_ref' FROM deliveries CROSS JOIN LATERAL jsonb_array_elements(COALESCE(payload->'attachments','[]')) a WHERE a->>'blob_ref' IS NOT NULL"
        )

    files =
      Map.new(rows!("SELECT encode(sha256,'hex'),sha256,size,created_at FROM files"), fn [
                                                                                           hex,
                                                                                           sha,
                                                                                           size,
                                                                                           time
                                                                                         ] ->
        {hex, {sha, size, time}}
      end)

    for [tenant, hash] <- required do
      unless Map.has_key?(files, hash),
        do:
          raise(
            "Referenced legacy blob is missing: tenant=#{uuid_text(tenant)} hash=#{inspect(hash)}"
          )
    end

    refs =
      (required ++ optional)
      |> Enum.uniq()
      |> Enum.filter(fn [_, hash] -> Map.has_key?(files, hash) end)
      |> Enum.sort()

    {map, _keys} =
      Enum.reduce(refs, {%{}, MapSet.new()}, fn [tenant, hash], {map, used} ->
        {sha, size, time} = Map.fetch!(files, hash)
        id = uuid()
        old_key = "blobs/" <> hash

        key =
          if MapSet.member?(used, hash),
            do: "tenants/#{uuid_text(tenant)}/objects/#{uuid_text(id)}",
            else: old_key

        if key != old_key, do: copy_object!(old_key, key, hash, size)

        query!(
          "INSERT INTO file_objects(tenant_id,id,storage_key,sha256,size,completed_at,created_at) VALUES($1,$2,$3,$4,$5,$6,$6)",
          [tenant, id, key, sha, size, utc(time)]
        )

        {Map.put(map, {tenant, hash}, id), MapSet.put(used, hash)}
      end)

    map
  end

  defp copy_object!(from, to, hash, size) do
    Process.put({__MODULE__, :copied_keys}, [to | Process.get({__MODULE__, :copied_keys}, [])])

    chunks =
      Stream.unfold(0, fn offset ->
        if offset < size do
          length = min(1024 * 1024, size - offset)

          case Ankole.ObjectStore.read_range(from, offset, length) do
            {:ok, bytes} -> {bytes, offset + length}
            {:error, reason} -> raise "Cannot migrate #{from}: #{inspect(reason)}"
          end
        end
      end)

    case Ankole.ObjectStore.write_stream(to, chunks) do
      {:ok, %{sha256: ^hash, size: ^size}} -> :ok
      result -> raise "Cannot copy legacy object #{from} to #{to}: #{inspect(result)}"
    end
  end

  defp migrate_paths!(roots, objects) do
    for file <- maps!("SELECT * FROM drive_files ORDER BY tenant_id,agent_uid NULLS FIRST,path") do
      tenant = file["tenant_id"]
      object = Map.fetch!(objects, {tenant, Base.encode16(file["sha256"], case: :lower)})

      case {file["agent_uid"], String.split(file["path"], "/", parts: 3)} do
        {nil, ["pages", page_id, relative]} ->
          page = Ecto.UUID.dump!(page_id)

          case rows!("SELECT kind FROM drive_nodes WHERE tenant_id=$1 AND id=$2", [tenant, page]) do
            [["file"]] ->
              [[count]] =
                rows!(
                  "SELECT count(*) FROM drive_nodes WHERE tenant_id=$1 AND id=$2 AND object_id IS NOT NULL",
                  [tenant, page]
                )

              if count > 0, do: raise("File page #{page_id} has multiple primary files")

              query!(
                "UPDATE drive_nodes SET object_id=$3,content_type=$4,mode=$5,source=$6 WHERE tenant_id=$1 AND id=$2",
                [tenant, page, object, file["content_type"], file["mode"], file["source"]]
              )

            [[_kind]] ->
              insert_pod_file!(file, page, relative, object)

            [] ->
              raise "Pod file references missing page #{page_id}"
          end

        {nil, _} ->
          insert_pod_file!(file, nil, file["path"], object)

        {uid, _} ->
          root = Map.fetch!(roots, {tenant, {:private, uid}})
          components = String.split(file["path"], "/")
          {folders, [name]} = Enum.split(components, -1)
          parent = Enum.reduce(folders, root, &ensure_folder!(tenant, &2, &1))

          if byte_size(name) > 255,
            do: raise("Drive name exceeds 255 bytes: #{inspect(file["path"])}")

          insert_node!(tenant, %{
            parent_id: parent,
            name: unique_name!(tenant, parent, name),
            kind: "file",
            object_id: object,
            content_type: file["content_type"],
            mode: file["mode"],
            source: file["source"],
            message_id: file["message_id"],
            source_conversation_id: file["conversation_id"],
            created_at: file["inserted_at"],
            updated_at: file["updated_at"]
          })
      end
    end
  end

  defp insert_pod_file!(file, node, path, object) do
    query!(
      "INSERT INTO pod_files(tenant_id,id,node_id,path,object_id,mode,content_type,source,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)",
      [
        file["tenant_id"],
        uuid(),
        node,
        path,
        object,
        file["mode"],
        file["content_type"],
        file["source"],
        utc(file["inserted_at"]),
        utc(file["updated_at"])
      ]
    )
  end

  defp ensure_folder!(tenant, parent, name) do
    case rows!(
           "SELECT id,kind FROM drive_nodes WHERE tenant_id=$1 AND parent_id=$2 AND name=$3 AND deleted_at IS NULL",
           [tenant, parent, name]
         ) do
      [[id, "folder"]] -> id
      [] -> insert_node!(tenant, %{parent_id: parent, name: name, kind: "folder"})
      _ -> raise "Legacy path needs a directory where a file already exists: #{inspect(name)}"
    end
  end

  defp migrate_attachments!(roots, objects) do
    for [tenant, message, conversation, attachments, created_at] <-
          rows!(
            "SELECT tenant_id,id,conversation_id,attachments,created_at FROM conversation_messages ORDER BY tenant_id,id"
          ) do
      for {attachment, position} <- Enum.with_index(attachments) do
        object = Map.get(objects, {tenant, attachment["blob_ref"]})

        node =
          if object do
            parent = Map.fetch!(roots, {tenant, {:conversation, conversation}})

            name =
              unique_name!(
                tenant,
                parent,
                safe_name(
                  attachment["name"] || Path.basename(attachment["path"] || "attachment"),
                  "attachment"
                )
              )

            insert_node!(tenant, %{
              parent_id: parent,
              name: name,
              kind: "file",
              object_id: object,
              source: "inbound",
              message_id: message,
              content_type: attachment["content_type"] || attachment["mime_type"],
              created_at: created_at,
              updated_at: created_at
            })
          end

        query!(
          "INSERT INTO message_attachments(tenant_id,message_id,position,object_id,node_id,metadata) VALUES($1,$2,$3,$4,$5,$6)",
          [
            tenant,
            message,
            position,
            object,
            node,
            Map.drop(attachment, ~w(blob_ref object_id node_id))
          ]
        )
      end
    end

    for [tenant, uid, binding, key, status, payload] <-
          rows!(
            "SELECT tenant_id,agent_uid,binding_name,outbound_key,status,payload FROM deliveries"
          ) do
      for {attachment, position} <- Enum.with_index(Map.get(payload, "attachments", [])) do
        object =
          if status in ~w(pending failed unknown),
            do: Map.get(objects, {tenant, attachment["blob_ref"]})

        query!(
          "INSERT INTO delivery_attachments(tenant_id,agent_uid,binding_name,outbound_key,position,object_id,metadata) VALUES($1,$2,$3,$4,$5,$6,$7)",
          [
            tenant,
            uid,
            binding,
            key,
            position,
            object,
            Map.drop(attachment, ~w(blob_ref object_id node_id))
          ]
        )
      end

      payload = Map.delete(payload, "attachments")

      query!(
        "UPDATE deliveries SET payload=$5 WHERE tenant_id=$1 AND agent_uid=$2 AND binding_name=$3 AND outbound_key=$4",
        [tenant, uid, binding, key, payload]
      )
    end
  end

  defp json_rows do
    calls = reply_attachment_calls()

    Enum.flat_map(@json_fields, fn {table, column, shape, filter} ->
      if shape in [:response_items, :compaction] do
        for [tenant, ctid, subject, conversation, value] <-
              rows!(
                "SELECT tenant_id,ctid::text,subject_uid,conversation_id,#{column} FROM #{table} WHERE #{column} IS NOT NULL"
              ) do
          ids = Map.get(calls, {tenant, subject, conversation}, MapSet.new())
          {table, column, {shape, ids}, tenant, ctid, value}
        end
      else
        for [tenant, ctid, value] <-
              rows!(
                "SELECT tenant_id,ctid::text,#{column} FROM #{table} WHERE #{column} IS NOT NULL AND (#{filter})"
              ),
            do: {table, column, shape, tenant, ctid, value}
      end
    end)
  end

  defp reply_attachment_calls do
    # Completion replay pairs outputs with named calls across response rows.
    rows!("""
    WITH items AS (
      SELECT tenant_id,subject_uid,conversation_id,item
      FROM ai_gateway_messages CROSS JOIN LATERAL jsonb_array_elements(COALESCE(content,'[]')) item
      UNION ALL
      SELECT tenant_id,subject_uid,conversation_id,item
      FROM ai_gateway_compaction_artifacts
        CROSS JOIN LATERAL jsonb_array_elements(COALESCE(content->'output','[]') || COALESCE(content->'opaque_prefix','[]')) item
    )
    SELECT DISTINCT tenant_id,subject_uid,conversation_id,item->>'call_id'
    FROM items WHERE item->>'type'='function_call' AND item->>'name'='reply_attachment' AND item->>'call_id' IS NOT NULL
    """)
    |> Enum.reduce(%{}, fn [tenant, subject, conversation, id], calls ->
      Map.update(calls, {tenant, subject, conversation}, MapSet.new([id]), &MapSet.put(&1, id))
    end)
  end

  defp rewrite_json_references!(objects) do
    for {table, column, shape, tenant, ctid, value} <- json_rows() do
      {rewritten, _} =
        attachment_refs(value, shape, nil, fn attachment, acc ->
          id = Map.get(objects, {tenant, attachment["blob_ref"]})

          {attachment
           |> Map.delete("blob_ref")
           |> Map.put("object_id", if(id, do: uuid_text(id))), acc}
        end)

      if rewritten != value,
        do:
          query!("UPDATE #{table} SET #{column}=$3 WHERE tenant_id=$1 AND ctid=$2::text::tid", [
            tenant,
            ctid,
            rewritten
          ])
    end
  end

  # Discovery and conversion walk exactly the same bounded shapes. In particular,
  # never decode a user message or arbitrary tool output just because it is JSON.
  defp attachment_refs(values, shape, acc, fun)
       when is_list(values) and shape in [:messages, :attachments] do
    child = %{messages: :message, attachments: :attachment}[shape]
    Enum.map_reduce(values, acc, &attachment_refs(&1, child, &2, fun))
  end

  defp attachment_refs(%{"blob_ref" => hash} = value, :attachment, acc, fun)
       when is_binary(hash),
       do: fun.(value, acc)

  defp attachment_refs(value, :message, acc, fun) when is_map(value),
    do: attachment_slots(value, [{"attachments", :attachments}, {"reply_to", :message}], acc, fun)

  defp attachment_refs(value, :signal, acc, fun) when is_map(value) do
    {value, acc} = attachment_refs(value, :message, acc, fun)

    attachment_slots(
      value,
      [{"entry", :message}] ++
        Enum.map(
          ~w(entries unreplied_messages observed_messages backdrop_messages),
          &{&1, :messages}
        ),
      acc,
      fun
    )
  end

  defp attachment_refs(values, {:response_items, calls}, acc, fun) when is_list(values) do
    Enum.map_reduce(values, acc, fn
      %{"type" => "function_call_output", "call_id" => id} = value, acc ->
        if MapSet.member?(calls, id),
          do: attachment_refs(value, :response_item, acc, fun),
          else: {value, acc}

      value, acc ->
        {value, acc}
    end)
  end

  defp attachment_refs(value, {:compaction, calls}, acc, fun) when is_map(value),
    do:
      attachment_slots(
        value,
        [{"output", {:response_items, calls}}, {"opaque_prefix", {:response_items, calls}}],
        acc,
        fun
      )

  defp attachment_refs(%{"type" => "function_call_output"} = value, :response_item, acc, fun),
    do: attachment_slots(value, [{"output", :reply_attachment_output}], acc, fun)

  defp attachment_refs(value, :reply_attachment_output, acc, fun) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, %{"tool" => "reply_attachment"} = output} ->
        {rewritten, acc} = attachment_refs(output, :reply_attachment_output, acc, fun)
        {if(rewritten == output, do: value, else: JSON.encode!(rewritten)), acc}

      _ ->
        {value, acc}
    end
  end

  defp attachment_refs(
         %{"tool" => "reply_attachment"} = value,
         :reply_attachment_output,
         acc,
         fun
       ),
       do: attachment_slots(value, [{"attachments", :attachments}], acc, fun)

  defp attachment_refs(value, _shape, acc, _fun), do: {value, acc}

  defp attachment_slots(value, slots, acc, fun) do
    Enum.reduce(slots, {value, acc}, fn {key, shape}, {value, acc} ->
      case Map.fetch(value, key) do
        {:ok, child} ->
          {child, acc} = attachment_refs(child, shape, acc, fun)
          {Map.put(value, key, child), acc}

        :error ->
          {value, acc}
      end
    end)
  end

  defp preflight_file_parents! do
    conflicts =
      rows!("""
      SELECT child.tenant_id::text, parent.id::text, child.id::text
      FROM pages child JOIN pages parent
        ON parent.tenant_id=child.tenant_id AND parent.id=child.parent_id
      WHERE parent.type='file'
      ORDER BY child.tenant_id,parent.id,child.id
      """)

    if conflicts != [],
      do:
        raise(
          "File Pages have child nodes; move those children before upgrading " <>
            "(tenant,file_page,child_page): #{inspect(conflicts, limit: :infinity)}"
        )
  end

  defp preflight_conditions! do
    for [id, condition] <-
          rows!(
            "SELECT id,condition FROM permission_grants WHERE condition<>'true' AND (resource_pattern LIKE 'pod:%' OR resource_pattern IN ('tenant_console:pod_space','site_console:files') OR resource_pattern LIKE 'site_console:agent:%:files' OR action=ANY($1))",
            [@old_actions]
          ) do
      case Ankole.Kernel.authz_condition_free_variables(condition) do
        variables when is_list(variables) ->
          if Enum.any?(variables, &(&1 in ["resource", "action"])),
            do:
              raise(
                "Grant #{uuid_text(id)} refers to renamed resource/action variables; rewrite its condition before upgrading"
              )

        error ->
          raise "Cannot parse grant #{uuid_text(id)}: #{inspect(error)}"
      end
    end
  end

  defp legacy_agent_file_grants! do
    maps!("""
    SELECT g.id,g.resource_pattern,g.action,p.uid AS agent_uid
    FROM permission_grants g
    LEFT JOIN principals p ON p.tenant_id=g.tenant_id AND p.type='agent'
      AND g.resource_pattern='site_console:agent:'||p.uid||':files'
    WHERE g.resource_pattern LIKE 'site_console:agent:%:files'
      AND g.resource_pattern<>'site_console:agent:*:files'
    ORDER BY g.id
    """)
    |> Enum.map(fn grant ->
      uid = grant["agent_uid"]

      if is_nil(uid) or String.contains?(uid, ["*", "?", "[", "]", "{", "}"]) or
           grant["action"] not in ["read", "update", "delete"] do
        raise "Grant #{uuid_text(grant["id"])} cannot map #{grant["resource_pattern"]} " <>
                "(#{grant["action"]}) to one Agent in its tenant; adjust this grant before upgrading"
      end

      grant
    end)
  end

  # Console permissions were separate from Page permissions. Convert them only
  # after verifying the unchanged Page grants, into the approved private scope.
  defp migrate_agent_file_grants!(grants) do
    for grant <- grants do
      actions =
        case grant["action"] do
          "read" -> ["node_view"]
          "update" -> ~w(node_view node_contribute node_edit)
          "delete" -> ["node_edit"]
        end

      for action <- actions do
        query!(
          """
          INSERT INTO permission_grants
            (id,tenant_id,principal_uid,group_id,resource_pattern,action,condition,
             description,metadata,inserted_at,updated_at)
          SELECT $1,tenant_id,principal_uid,group_id,$2,$3,condition,
            description,metadata,inserted_at,updated_at
          FROM permission_grants WHERE id=$4
          ON CONFLICT DO NOTHING
          """,
          [uuid(), "drive:private:#{grant["agent_uid"]}:**", action, grant["id"]]
        )
      end

      query!("DELETE FROM permission_grants WHERE id=$1", [grant["id"]])
    end
  end

  defp migrate_grants! do
    statements!("""
    ALTER TABLE permission_grants DROP CONSTRAINT permission_grants_owner_shape;
    ALTER TABLE permission_grants DROP CONSTRAINT permission_grants_pod_action_shape;
    ALTER TABLE permission_grants DROP CONSTRAINT permission_grants_source_page_fkey;
    ALTER TABLE permission_grants DROP CONSTRAINT permission_grants_target_page_fkey;
    ALTER TABLE permission_grants RENAME COLUMN source_page_id TO source_node_id;
    ALTER TABLE permission_grants RENAME COLUMN target_page_id TO target_node_id;
    DROP INDEX permission_grants_pod_target_index;
    DROP INDEX permission_grants_pod_userset_edge_index;
    """)

    rewrites =
      maps!(
        "SELECT id,tenant_id,principal_uid,group_id,source_node_id,resource_pattern,action,source_action,condition FROM permission_grants ORDER BY id"
      )
      |> Enum.group_by(fn grant ->
        {grant["tenant_id"], grant["principal_uid"], grant["group_id"], grant["source_node_id"],
         pattern(grant["resource_pattern"]), action(grant["action"]),
         action(grant["source_action"]), grant["condition"]}
      end)

    for {_identity, [_first | duplicates]} <- rewrites,
        duplicate <- duplicates,
        do: query!("DELETE FROM permission_grants WHERE id=$1", [duplicate["id"]])

    for {_identity, [grant | _]} <- rewrites do
      query!(
        "UPDATE permission_grants SET resource_pattern=$2,action=$3,source_action=$4 WHERE id=$1",
        [
          grant["id"],
          pattern(grant["resource_pattern"]),
          action(grant["action"]),
          action(grant["source_action"])
        ]
      )
    end

    actions = Enum.map_join(@actions, ",", &("'" <> &1 <> "'"))

    statements!("""
    ALTER TABLE permission_grants ADD CONSTRAINT permission_grants_owner_shape CHECK (
      num_nonnulls(principal_uid,group_id,source_node_id)=1 AND (
        (source_node_id IS NULL AND source_action IS NULL) OR
        (source_node_id IS NOT NULL AND source_action IN (#{actions}) AND target_node_id IS NOT NULL)
      )
    );
    ALTER TABLE permission_grants ADD CONSTRAINT permission_grants_drive_action_shape CHECK (
      (action NOT IN (#{actions}) AND target_node_id IS NULL AND target_scope IS NULL AND resource_pattern<>'**' AND resource_pattern NOT LIKE 'drive:%') OR
      (action IN (#{actions}) AND (
        (target_node_id IS NULL AND target_scope IS NULL AND (resource_pattern='drive:space:**' OR resource_pattern ~ '^drive:private:[^*?\\[\\]{}]+:\\*\\*$')) OR
        (target_node_id IS NOT NULL AND target_scope IN ('container','self') AND
          resource_pattern=('drive:**:'||target_node_id::text||':'||CASE target_scope WHEN 'container' THEN '**' ELSE 'node' END) AND
          (source_node_id IS NULL OR source_node_id<>target_node_id))
      ))
    );
    ALTER TABLE permission_grants ADD CONSTRAINT permission_grants_source_node_fkey FOREIGN KEY(tenant_id,source_node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE;
    ALTER TABLE permission_grants ADD CONSTRAINT permission_grants_target_node_fkey FOREIGN KEY(tenant_id,target_node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE;
    CREATE INDEX permission_grants_drive_target_index ON permission_grants(tenant_id,target_node_id,target_scope,action) WHERE target_node_id IS NOT NULL;
    CREATE INDEX permission_grants_drive_userset_edge_index ON permission_grants(tenant_id,source_node_id,source_action) INCLUDE(target_node_id,target_scope,action,condition) WHERE source_node_id IS NOT NULL;
    """)
  end

  defp finish_nodes! do
    query!("SET CONSTRAINTS drive_nodes_parent_fkey IMMEDIATE")

    query!("""
    WITH RECURSIVE computed AS (
      SELECT tenant_id,id,id AS acl_anchor_id,NULL::uuid AS parent_anchor_id FROM drive_nodes WHERE parent_id IS NULL
      UNION ALL
      SELECT c.tenant_id,c.id,CASE WHEN c.is_acl_anchor THEN c.id ELSE p.acl_anchor_id END,
        CASE WHEN c.is_acl_anchor THEN p.acl_anchor_id ELSE NULL END
      FROM drive_nodes c JOIN computed p ON c.tenant_id=p.tenant_id AND c.parent_id=p.id
    ) UPDATE drive_nodes n SET acl_anchor_id=c.acl_anchor_id,parent_anchor_id=c.parent_anchor_id
      FROM computed c WHERE n.tenant_id=c.tenant_id AND n.id=c.id
    """)

    statements!("""
    ALTER TABLE drive_nodes ALTER COLUMN acl_anchor_id SET NOT NULL;
    ALTER TABLE drive_nodes ADD CONSTRAINT drive_nodes_acl_anchor_shape CHECK (
      (is_acl_anchor AND acl_anchor_id=id AND ((parent_id IS NULL AND parent_anchor_id IS NULL) OR (parent_id IS NOT NULL AND parent_anchor_id IS NOT NULL AND parent_anchor_id<>id))) OR
      (NOT is_acl_anchor AND parent_id IS NOT NULL AND acl_anchor_id<>id AND parent_anchor_id IS NULL)
    );
    ALTER TABLE drive_nodes ADD CONSTRAINT drive_nodes_acl_anchor_fkey FOREIGN KEY(tenant_id,acl_anchor_id) REFERENCES drive_nodes(tenant_id,id) DEFERRABLE INITIALLY IMMEDIATE;
    ALTER TABLE drive_nodes ADD CONSTRAINT drive_nodes_parent_anchor_fkey FOREIGN KEY(tenant_id,parent_anchor_id) REFERENCES drive_nodes(tenant_id,id) DEFERRABLE INITIALLY IMMEDIATE;
    ALTER TABLE drive_nodes ALTER CONSTRAINT drive_nodes_parent_fkey INITIALLY IMMEDIATE;
    """)
  end

  defp finish_schema! do
    statements!("""
    ALTER TABLE pages ALTER COLUMN position DROP NOT NULL;
    ALTER TABLE pages ADD CONSTRAINT pages_node_fkey FOREIGN KEY(tenant_id,id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE;
    ALTER TABLE pages DROP COLUMN is_acl_anchor;
    ALTER TABLE pages DROP COLUMN parent_id, DROP COLUMN private_owner_uid, DROP COLUMN type,
      DROP COLUMN inherit_permissions, DROP COLUMN has_local_acl,
      DROP COLUMN acl_anchor_id, DROP COLUMN parent_anchor_id, DROP COLUMN deleted_at,
      DROP COLUMN purge_started_at, DROP COLUMN created_by;
    CREATE INDEX pages_title_trgm_gin_index ON pages USING gin(title gin_trgm_ops);
    ALTER TABLE conversation_messages DROP CONSTRAINT IF EXISTS conversation_messages_text_present;
    ALTER TABLE conversation_messages DROP COLUMN attachments;
    """)

    query!("""
    CREATE VIEW pod_page_nodes AS SELECT n.tenant_id,n.id,n.parent_id,n.private_owner_uid,n.kind AS type,
      CASE WHEN n.kind IN ('folder','file') THEN n.name ELSE COALESCE(p.title,'') END AS title,
      p.icon,p.position,n.inherit_permissions,n.has_local_acl,n.is_acl_anchor,n.acl_anchor_id,n.parent_anchor_id,
      COALESCE(p.revision,0) AS revision,p.saved_from_message_id,COALESCE(p.children_view,'{}'::jsonb) AS children_view,
      n.created_by,n.deleted_at,n.purge_started_at,n.created_at,GREATEST(n.updated_at,p.updated_at) AS updated_at,
      n.name,n.conversation_id,n.object_id,(n.parent_id IS NULL) AS is_root
    FROM drive_nodes n LEFT JOIN pages p ON p.tenant_id=n.tenant_id AND p.id=n.id
    """)

    # Native message text and attachment rows form one invariant. Deferred checks
    # permit the owner to insert the message and its references in either order.
    query!("""
    CREATE FUNCTION check_conversation_message_content() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE owner_tenant uuid; owner_message uuid;
    BEGIN
      IF TG_TABLE_NAME='conversation_messages' THEN
        owner_tenant=NEW.tenant_id; owner_message=NEW.id;
      ELSE
        owner_tenant=COALESCE(NEW.tenant_id,OLD.tenant_id); owner_message=COALESCE(NEW.message_id,OLD.message_id);
      END IF;
      IF EXISTS (SELECT 1 FROM conversation_messages m WHERE m.tenant_id=owner_tenant AND m.id=owner_message
        AND m.origin='native' AND btrim(COALESCE(m.text,''))='' AND NOT EXISTS (
          SELECT 1 FROM message_attachments a WHERE a.tenant_id=m.tenant_id AND a.message_id=m.id)) THEN
        RAISE EXCEPTION 'Native messages require text or an attachment' USING ERRCODE='23514',CONSTRAINT='conversation_messages_text_present';
      END IF;
      RETURN NULL;
    END $$
    """)

    query!(
      "CREATE CONSTRAINT TRIGGER conversation_messages_content_present AFTER INSERT OR UPDATE ON conversation_messages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_conversation_message_content()"
    )

    query!(
      "CREATE CONSTRAINT TRIGGER message_attachments_content_present AFTER DELETE OR UPDATE ON message_attachments DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION check_conversation_message_content()"
    )
  end

  defp enqueue_unreferenced_legacy_objects! do
    for [key] <-
          rows!(
            "SELECT 'blobs/'||encode(f.sha256,'hex') FROM files f WHERE NOT EXISTS (SELECT 1 FROM file_objects o WHERE o.storage_key='blobs/'||encode(f.sha256,'hex'))"
          ) do
      # Insert the Oban outbox directly because releases migrate before starting Oban.
      query!(
        "INSERT INTO oban_jobs(queue,worker,args,max_attempts,inserted_at,scheduled_at) VALUES('default','Ankole.Files.Jobs.DeleteObject',$1,20,now(),now())",
        [%{"storage_key" => key}]
      )
    end
  end

  defp permission_snapshots!(table, converted?) do
    sources = if converted?, do: "source_node_id", else: "source_page_id"
    nodes = maps!("SELECT tenant_id,id,is_acl_anchor,acl_anchor_id FROM #{table}")

    nodes =
      if converted? do
        old_ids = MapSet.new(rows!("SELECT tenant_id,id FROM pages"), &List.to_tuple/1)
        Enum.filter(nodes, &MapSet.member?(old_ids, {&1["tenant_id"], &1["id"]}))
      else
        nodes
      end

    nodes = Enum.group_by(nodes, & &1["tenant_id"])

    Enum.reduce(
      maps!(
        "SELECT tenant_id,uid,type,status,membership,display_name,avatar_url FROM principals ORDER BY tenant_id,uid"
      ),
      %{},
      fn principal, result ->
        tenant = principal["tenant_id"]
        uid = principal["uid"]

        snapshot = %{
          "principal" => %{
            "uid" => uid,
            "type" => principal["type"],
            "status" => principal["status"],
            "membership" => principal["membership"],
            "displayName" => principal["display_name"],
            "avatarURL" => principal["avatar_url"]
          },
          "staticGroupIDs" =>
            List.flatten(
              rows!(
                "SELECT group_id::text FROM principal_group_memberships WHERE tenant_id=$1 AND principal_uid=$2",
                [tenant, uid]
              )
            ),
          "computedGroups" =>
            Enum.map(
              rows!(
                "SELECT id::text,computed_condition FROM principal_groups WHERE tenant_id=$1 AND kind='computed'",
                [tenant]
              ),
              fn [id, condition] -> %{"id" => id, "condition" => condition || "false"} end
            ),
          "grants" =>
            Enum.map(
              maps!(
                "SELECT id::text,principal_uid,group_id::text,resource_pattern,action,condition,(#{sources} IS NOT NULL) AS userset FROM permission_grants WHERE tenant_id=$1",
                [tenant]
              ),
              fn grant ->
                %{
                  "id" => grant["id"],
                  "principalUID" => grant["principal_uid"],
                  "groupID" => grant["group_id"],
                  "resourcePattern" => pattern(grant["resource_pattern"]),
                  "action" => action(grant["action"]),
                  "condition" => grant["condition"],
                  "hasSourceNode" => grant["userset"]
                }
              end
            ),
          "context" => %{}
        }

        evaluated = Ankole.Kernel.authz_evaluate_drive_context(snapshot)

        reachable =
          if principal["status"] == "active" do
            params = [
              uuid_text(tenant),
              evaluated["satisfiedGrantIDs"],
              uid,
              evaluated["effectiveGroupIDs"],
              space_bits(snapshot, evaluated),
              principal["membership"] == "guest",
              nil,
              nil,
              nil
            ]

            Map.new(rows!(graph_sql(converted?), params), fn [id, container, own] ->
              {id, {container, own}}
            end)
          else
            %{}
          end

        Enum.reduce(Map.get(nodes, tenant, []), result, fn node, acc ->
          {container, own} = Map.get(reachable, uuid_text(node["acl_anchor_id"]), {0, 0})

          Map.put(
            acc,
            {uuid_text(tenant), uid, uuid_text(node["id"])},
            if(node["is_acl_anchor"], do: own, else: container)
          )
        end)
      end
    )
  end

  defp space_bits(%{"principal" => %{"membership" => "guest"}}, _), do: 0

  defp space_bits(snapshot, evaluated) do
    manager =
      snapshot
      |> Map.put("resource", "tenant_console:drive_space")
      |> Map.put("action", "update")
      |> Ankole.Kernel.authz_authorize()

    if manager["status"] == "allow" do
      31
    else
      Enum.reduce(snapshot["grants"], 0, fn grant, bits ->
        owned =
          grant["principalUID"] == snapshot["principal"]["uid"] or
            grant["groupID"] in evaluated["effectiveGroupIDs"]

        if owned and grant["resourcePattern"] == "drive:space:**" and grant["action"] in @actions and
             (grant["condition"] == "true" or grant["id"] in evaluated["satisfiedGrantIDs"]),
           do:
             bor(
               bits,
               Enum.at([1, 2, 4, 8, 16], Enum.find_index(@actions, &(&1 == grant["action"])))
             ),
           else: bits
      end)
    end
  end

  defp verify_permissions!(before, after_snapshots) do
    changed = Enum.filter(before, fn {key, bits} -> Map.get(after_snapshots, key) != bits end)

    if changed != [],
      do:
        raise(
          "Drive migration changes effective permissions (tenant,principal,page / old,new): #{inspect(Enum.take(Enum.map(changed, fn {key, bits} -> {key, bits, Map.get(after_snapshots, key)} end), 20))}"
        )
  end

  defp graph_sql(false), do: legacy_graph_sql()

  defp graph_sql(true) do
    legacy_graph_sql()
    |> String.replace("pages", "drive_nodes")
    |> String.replace("source_page_id", "source_node_id")
    |> String.replace("target_page_id", "target_node_id")
    |> String.replace("pod:private:", "drive:private:")
    |> then(fn sql ->
      Enum.zip(@old_actions, @actions)
      |> Enum.reduce(sql, fn {old, new}, sql -> String.replace(sql, old, new) end)
    end)
    # Public grants must never seed a conversation root.
    |> String.replace(
      "AND la.private_owner_uid IS NULL",
      "AND la.private_owner_uid IS NULL AND la.id NOT IN (SELECT id FROM drive_nodes WHERE tenant_id=$1::text::uuid AND conversation_id IS NOT NULL)"
    )
  end

  defp action(nil), do: nil
  defp action(value), do: Map.get(Map.new(Enum.zip(@old_actions, @actions)), value, value)
  defp pattern("pod:" <> rest), do: "drive:" <> String.replace_suffix(rest, ":page", ":node")
  defp pattern("tenant_console:pod_space"), do: "tenant_console:drive_space"
  defp pattern("site_console:files"), do: "site_console:drive"

  defp pattern("site_console:agent:*:files"), do: "site_console:drive"
  defp pattern(value), do: value

  defp insert_node!(tenant, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {key, utc(value)} end) |> Map.put_new(:id, uuid())
    columns = [:tenant_id | Map.keys(attrs)]
    params = [tenant | Map.values(attrs)]

    query!(
      "INSERT INTO drive_nodes(#{Enum.join(columns, ",")}) VALUES(#{Enum.map_join(1..length(params), ",", &"$#{&1}")})",
      params
    )

    attrs.id
  end

  defp unique_name!(tenant, parent, name, index \\ 1) do
    suffix = if index == 1, do: "", else: " (#{index})"
    candidate = truncate_utf8(name, 255 - byte_size(suffix)) <> suffix

    case rows!(
           "SELECT 1 FROM drive_nodes WHERE tenant_id=$1 AND parent_id=$2 AND name=$3 AND deleted_at IS NULL",
           [tenant, parent, candidate]
         ) do
      [] -> candidate
      _ -> unique_name!(tenant, parent, name, index + 1)
    end
  end

  defp safe_name(name, fallback) do
    name = name |> to_string() |> String.replace(~r/[\x00-\x1f\x7f\/]/u, " ") |> String.trim()
    if name in ["", ".", ".."], do: fallback, else: truncate_utf8(name, 255)
  end

  defp truncate_utf8(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn char, acc ->
      if byte_size(acc <> char) <= max, do: {:cont, acc <> char}, else: {:halt, acc}
    end)
  end

  defp utc(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp utc(value), do: value
  defp uuid, do: Ecto.UUID.dump!(Ankole.Ecto.UUIDv7.autogenerate())
  defp uuid_text(nil), do: nil
  defp uuid_text(value), do: Ecto.UUID.load!(value)
  defp query!(sql, params \\ []), do: repo().query!(sql, params, timeout: :infinity)
  defp rows!(sql, params \\ []), do: query!(sql, params).rows

  defp maps!(sql, params \\ []) do
    %{columns: columns, rows: rows} = query!(sql, params)
    Enum.map(rows, &Map.new(Enum.zip(columns, &1)))
  end

  defp statements!(sql), do: Enum.each(String.split(sql, ";", trim: true), &query!/1)

  # Frozen pre-cutover SQL keeps this migration independent of later runtime changes.
  defp legacy_graph_sql do
    """
      SELECT graph.anchor_id, graph.container_bits, graph.self_bits
      FROM unnest(COALESCE($9::text[], ARRAY[$8::text])) AS candidate(trash_id)
      CROSS JOIN LATERAL (
        WITH RECURSIVE
        dependencies (id) AS (
          SELECT unnest((CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END)::uuid[])
          UNION
          SELECT dependency.id
          FROM dependencies d
          CROSS JOIN LATERAL (
            SELECT p.parent_anchor_id AS id FROM pages p
            WHERE p.tenant_id = $1::text::uuid AND p.id = d.id
              AND p.parent_anchor_id IS NOT NULL
            UNION ALL
            SELECT source.acl_anchor_id FROM permission_grants g
            JOIN pages source ON source.tenant_id = g.tenant_id AND source.id = g.source_page_id
            WHERE g.tenant_id = $1::text::uuid AND g.target_page_id = d.id
              AND g.source_page_id IS NOT NULL
              AND g.action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage', 'page_comment')
              AND (g.condition = 'true' OR g.id = ANY($2::text[]::uuid[]))
          ) dependency
        ),
        all_anchors AS (
          SELECT id, parent_anchor_id, private_owner_uid, inherit_permissions, deleted_at
          FROM pages
          WHERE tenant_id = $1::text::uuid AND is_acl_anchor = true AND (CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END) IS NULL
          UNION ALL
          SELECT p.id, p.parent_anchor_id, p.private_owner_uid, p.inherit_permissions, p.deleted_at
          FROM dependencies d
          JOIN pages p ON p.tenant_id = $1::text::uuid AND p.id = d.id AND p.is_acl_anchor = true
          WHERE (CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END) IS NOT NULL
        ),
        trashed_anchors AS (
          SELECT id FROM all_anchors WHERE deleted_at IS NOT NULL AND id <> COALESCE((CASE WHEN $9::text[] IS NULL THEN $8::text ELSE candidate.trash_id END)::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
          UNION
          SELECT c.id
          FROM all_anchors c
          JOIN trashed_anchors t ON c.parent_anchor_id = t.id
        ),
        private_anchors AS (
          SELECT id FROM all_anchors WHERE private_owner_uid IS NOT NULL
          UNION
          SELECT c.id FROM all_anchors c JOIN private_anchors p ON c.parent_anchor_id = p.id
        ),
        live_anchors AS (
          SELECT a.id, a.parent_anchor_id, a.private_owner_uid, a.inherit_permissions
          FROM all_anchors a
          LEFT JOIN trashed_anchors t ON t.id = a.id
          WHERE t.id IS NULL AND (NOT $6::boolean OR a.id NOT IN (SELECT id FROM private_anchors))
        ),
        grant_candidates AS (
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.principal_uid = $3::text
            AND g.action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage', 'page_comment') AND g.condition = 'true'
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.group_id = ANY($4::text[]::uuid[])
            AND g.action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage', 'page_comment') AND g.condition = 'true'
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.source_page_id IS NOT NULL
            AND g.condition = 'true' AND g.action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage', 'page_comment')
            AND ((CASE WHEN $9::text[] IS NULL THEN $7::text[] ELSE ARRAY[candidate.trash_id] END) IS NULL
              OR g.target_page_id IN (SELECT id FROM dependencies))
          UNION ALL
          SELECT g.* FROM permission_grants g
          WHERE g.tenant_id = $1::text::uuid AND g.id = ANY($2::text[]::uuid[])
            AND g.action IN ('page_view', 'page_write_records', 'page_edit', 'page_manage', 'page_comment') AND g.condition <> 'true'
        ),
        active_grants AS (
          SELECT
            g.source_page_id,
            CASE g.source_action
              WHEN 'page_view' THEN 1
              WHEN 'page_write_records' THEN 2
              WHEN 'page_edit' THEN 4
              WHEN 'page_manage' THEN 8
              WHEN 'page_comment' THEN 16
            END AS req_bit,
            g.target_page_id,
            (g.target_scope = 'container') AS is_container,
            CASE g.action
              WHEN 'page_view' THEN 1
              WHEN 'page_write_records' THEN 2
              WHEN 'page_edit' THEN 4
              WHEN 'page_manage' THEN 8
              WHEN 'page_comment' THEN 16
            END AS grant_bit,
            g.resource_pattern
          FROM grant_candidates g
        ),
        seeds (anchor_id, scope, bit) AS (
          SELECT la.id, s.scope, b.bit
          FROM live_anchors la
          CROSS JOIN (VALUES (1), (2), (4), (8), (16)) AS b(bit)
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.parent_anchor_id IS NULL
            AND la.private_owner_uid IS NULL
            AND la.inherit_permissions = true
            AND ($5::integer & b.bit) <> 0

          UNION ALL

          SELECT la.id, s.scope, ag.grant_bit
          FROM live_anchors la
          JOIN active_grants ag
            ON ag.source_page_id IS NULL
           AND ag.target_page_id IS NULL
           AND ag.resource_pattern = ('pod:private:' || la.private_owner_uid || ':**')
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.private_owner_uid IS NOT NULL

          UNION ALL

          SELECT la.id, s.scope, ag.grant_bit
          FROM active_grants ag
          JOIN live_anchors la ON la.id = ag.target_page_id
          CROSS JOIN LATERAL (
            SELECT 'self'::text AS scope
            UNION ALL
            SELECT 'container'::text WHERE ag.is_container
          ) s
          WHERE ag.source_page_id IS NULL
        ),
        edges (src_anchor, src_scope, src_bit, dst_anchor, dst_scope, dst_bit) AS (
          SELECT la.parent_anchor_id, 'container', b.bit, la.id, s.scope, b.bit
          FROM live_anchors la
          CROSS JOIN (VALUES (1), (2), (4), (8), (16)) AS b(bit)
          CROSS JOIN (VALUES ('container'), ('self')) AS s(scope)
          WHERE la.parent_anchor_id IS NOT NULL
            AND la.inherit_permissions = true

          UNION ALL

          SELECT
            src.acl_anchor_id,
            CASE WHEN src.is_acl_anchor THEN 'self' ELSE 'container' END,
            ag.req_bit,
            tgt.id,
            s.scope,
            ag.grant_bit
          FROM active_grants ag
          JOIN pages src
            ON src.tenant_id = $1::text::uuid
           AND src.id = ag.source_page_id
           AND src.deleted_at IS NULL
          JOIN live_anchors src_live ON src_live.id = src.acl_anchor_id
          JOIN live_anchors tgt ON tgt.id = ag.target_page_id
          CROSS JOIN LATERAL (
            SELECT 'self'::text AS scope
            UNION ALL
            SELECT 'container'::text WHERE ag.is_container
          ) s
          WHERE ag.source_page_id IS NOT NULL
        ),
        reach (anchor_id, scope, bit) AS (
          SELECT anchor_id, scope, bit FROM seeds
          UNION
          SELECT e.dst_anchor, e.dst_scope, e.dst_bit
          FROM reach r
          JOIN edges e
            ON e.src_anchor = r.anchor_id
           AND e.src_scope = r.scope
           AND e.src_bit = r.bit
        )
        SELECT
          anchor_id::text,
          COALESCE(bit_or(bit) FILTER (WHERE scope = 'container'), 0) AS container_bits,
          bit_or(bit) AS self_bits
        FROM reach
        GROUP BY anchor_id
      ) graph
      WHERE $9::text[] IS NULL OR graph.anchor_id = candidate.trash_id
    """
  end
end
