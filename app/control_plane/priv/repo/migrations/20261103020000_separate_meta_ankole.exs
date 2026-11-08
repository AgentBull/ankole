defmodule Ankole.Repo.Migrations.SeparateMetaAnkole do
  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE conversation_action_cards DROP CONSTRAINT conversation_action_cards_action_kind_check"
    )

    execute(
      "ALTER TABLE conversation_action_cards ADD CONSTRAINT conversation_action_cards_action_kind_check CHECK (action_kind IN ('brain.object.create','pod.knowledge.save','pod.page.set_sharing','pod.page.delete','pod.page.restore','pod.base.delete_table','conversation.add_participants'))"
    )

    execute("ALTER TABLE agent_skills RENAME TO meta_legacy_agent_skills")
    execute("ALTER INDEX agent_skills_pkey RENAME TO meta_legacy_agent_skills_pkey")

    execute("""
    CREATE TABLE skills (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      slug text NOT NULL,
      name text NOT NULL,
      description text NOT NULL,
      manifest_xml text NOT NULL,
      manifest_markdown text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      enabled_for_all boolean NOT NULL DEFAULT false,
      source_kind text NOT NULL CHECK (source_kind IN ('builtin', 'agent_plugin', 'custom')),
      agent_plugin_id text,
      revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
      upstream_state jsonb NOT NULL DEFAULT '{}'::jsonb,
      created_by text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id),
      UNIQUE (tenant_id, slug),
      CONSTRAINT skills_slug_shape CHECK (slug ~ '^[a-z0-9][a-z0-9._-]{0,95}$'),
      CONSTRAINT skills_plugin_shape CHECK (
    (source_kind = 'agent_plugin') = (agent_plugin_id IS NOT NULL)
      )
    )
    """)

    execute("""
    CREATE TABLE skill_files (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      skill_id uuid NOT NULL,
      relative_path text NOT NULL,
      object_id uuid NOT NULL,
      mode integer NOT NULL DEFAULT 292 CHECK (mode IN (292, 365, 420, 493)),
      content_type text NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id),
      UNIQUE (tenant_id, skill_id, relative_path),
      FOREIGN KEY (tenant_id, skill_id) REFERENCES skills(tenant_id, id) ON DELETE CASCADE,
      FOREIGN KEY (tenant_id, object_id) REFERENCES file_objects(tenant_id, id) ON DELETE RESTRICT,
      CONSTRAINT skill_files_not_manifest CHECK (relative_path <> 'SKILL.md')
    )
    """)

    execute("""
    CREATE TABLE agent_skills (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      agent_uid text NOT NULL,
      skill_id uuid NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, agent_uid, skill_id),
      FOREIGN KEY (tenant_id, agent_uid) REFERENCES agents(tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE,
      FOREIGN KEY (tenant_id, skill_id) REFERENCES skills(tenant_id, id) ON DELETE CASCADE
    )
    """)

    execute("""
    CREATE TABLE agent_contracts (
      tenant_id uuid NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT,
      id uuid NOT NULL,
      agent_uid text,
      slot text NOT NULL CHECK (slot IN ('agents', 'design')),
      mode text NOT NULL CHECK (mode IN ('inherit', 'append', 'override')),
      content_xml text NOT NULL DEFAULT '<page />',
      content_markdown text NOT NULL DEFAULT '',
      metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
      revision bigint NOT NULL DEFAULT 1 CHECK (revision >= 1),
      upstream_state jsonb NOT NULL DEFAULT '{}'::jsonb,
      updated_by text,
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (tenant_id, id),
      FOREIGN KEY (tenant_id, agent_uid) REFERENCES agents(tenant_id, uid) ON UPDATE CASCADE ON DELETE CASCADE,
      CONSTRAINT agent_contracts_global_mode CHECK (agent_uid IS NOT NULL OR mode = 'override')
    )
    """)

    execute("""
    CREATE UNIQUE INDEX agent_contracts_global_slot_idx
      ON agent_contracts (tenant_id, slot) WHERE agent_uid IS NULL
    """)

    execute("""
    CREATE UNIQUE INDEX agent_contracts_agent_slot_idx
      ON agent_contracts (tenant_id, agent_uid, slot) WHERE agent_uid IS NOT NULL
    """)

    execute("""
    ALTER TABLE skill_files ADD CONSTRAINT skill_files_path_shape CHECK (
      relative_path <> '' AND left(relative_path,1) <> '/' AND right(relative_path,1) <> '/'
      AND position('//' in relative_path)=0 AND position(chr(92) in relative_path)=0
      AND NOT (string_to_array(relative_path,'/') && ARRAY['.','..']))
    """)

    flush()

    for [tenant] <- repo().query!("SELECT id::text FROM tenants").rows do
      Ankole.Repo.with_tenant(tenant, fn -> migrate_tenant(tenant) end)
    end

    execute("DROP TABLE meta_legacy_agent_skills")
    execute("DROP TABLE IF EXISTS agent_library_container_entries")
    execute("DELETE FROM app_configurations WHERE key='ai_agent.library.skill_defaults'")
    execute("DELETE FROM site_app_configurations WHERE key='ai_agent.library.skill_defaults'")
    execute("DROP INDEX pages_public_root_index")

    execute(
      "CREATE UNIQUE INDEX pages_public_root_index ON pages(tenant_id) WHERE parent_id IS NULL AND private_owner_uid IS NULL AND conversation_id IS NULL AND system_key IS NULL"
    )

    execute("ALTER TABLE pages DROP CONSTRAINT pages_root_shape")

    execute("""
    ALTER TABLE pages ADD CONSTRAINT pages_root_shape CHECK (
      (parent_id IS NULL AND type='doc' AND system_key IS NULL AND num_nonnulls(private_owner_uid,conversation_id)<=1)
      OR (parent_id IS NULL AND type='knowledge' AND system_key='ankole_brain' AND private_owner_uid IS NULL AND conversation_id IS NULL)
      OR (parent_id IS NOT NULL AND private_owner_uid IS NULL AND conversation_id IS NULL))
    """)

    execute(
      "UPDATE pages SET parent_id=NULL,parent_anchor_id=NULL,acl_anchor_id=id WHERE system_key='ankole_brain'"
    )

    execute("""
    UPDATE pages p SET system_key='ankole_brain_sources' FROM pages root
      WHERE p.tenant_id=root.tenant_id AND p.parent_id=root.id AND root.system_key='ankole_brain'
        AND p.name='sources' AND p.system_key IS NULL
    """)

    flush()
    convert_collaboration_knowledge()
    # Ankole.Upgrade202610 creates missing Brain roots, categories, and Agent
    # pages after the last migration, through the code of the final schema.
    mark_internal_profiles()

    execute("""
    CREATE FUNCTION meta_page_type_boundary() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE root_key text;
    BEGIN
      WITH RECURSIVE ancestors AS (
        SELECT id,parent_id,system_key FROM pages WHERE tenant_id=NEW.tenant_id AND id=NEW.id
        UNION ALL SELECT p.id,p.parent_id,p.system_key FROM pages p JOIN ancestors a ON a.parent_id=p.id
          WHERE p.tenant_id=NEW.tenant_id)
      SELECT system_key INTO root_key FROM ancestors WHERE parent_id IS NULL;
      IF (root_key IS DISTINCT FROM 'ankole_brain' AND NEW.type='knowledge') OR
         (root_key='ankole_brain' AND NEW.type NOT IN ('knowledge','file')) THEN
        RAISE EXCEPTION 'page type is outside its owning domain' USING ERRCODE='23514',CONSTRAINT='pages_domain_type';
      END IF;
      RETURN NEW;
    END $$
    """)

    execute(
      "CREATE CONSTRAINT TRIGGER pages_domain_type AFTER INSERT OR UPDATE OF parent_id,type ON pages DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION meta_page_type_boundary()"
    )
  end

  defp mark_internal_profiles do
    profiles =
      repo().query!("""
      WITH changed AS (
        UPDATE pages p SET metadata=(p.metadata - 'archived') || jsonb_build_object(
          'entity_type', CASE WHEN principal.type='human' THEN 'person' ELSE 'agent' END,
          'subtype','internal','uid',principal.uid) ||
          CASE WHEN principal.status='active' THEN '{}'::jsonb ELSE '{"archived":true}'::jsonb END
        FROM pages category, principals principal
        WHERE category.tenant_id=p.tenant_id AND category.id=p.parent_id
          AND principal.tenant_id=p.tenant_id AND principal.uid=p.name
          AND ((category.name='people' AND principal.type='human')
            OR (category.name='agents' AND principal.type='agent'))
          AND category.parent_id IN (SELECT id FROM pages WHERE system_key='ankole_brain')
        RETURNING p.tenant_id,p.id,p.metadata)
      SELECT p.tenant_id::text,p.id::text,coalesce(c.content,'<page />'),p.metadata FROM changed p
        LEFT JOIN page_contents c ON c.tenant_id=p.tenant_id AND c.page_id=p.id
      """).rows

    reproject(profiles, :knowledge)
  end

  defp convert_collaboration_knowledge do
    # Keep collaboration locations and IDs while using their owning document type.
    converted =
      repo().query!("""
      WITH RECURSIVE brain AS (
        SELECT tenant_id,id FROM pages WHERE system_key='ankole_brain'
        UNION ALL SELECT p.tenant_id,p.id FROM pages p JOIN brain b
          ON p.tenant_id=b.tenant_id AND p.parent_id=b.id),
      candidates AS (
        SELECT p.tenant_id,p.id FROM pages p WHERE p.type='knowledge'
          AND NOT EXISTS (SELECT 1 FROM brain b WHERE b.tenant_id=p.tenant_id AND b.id=p.id)
        LIMIT 100),
      changed AS (
        UPDATE pages p SET type='doc' FROM candidates c
          WHERE p.tenant_id=c.tenant_id AND p.id=c.id
        RETURNING p.tenant_id,p.id,p.metadata)
      SELECT p.tenant_id::text,p.id::text,c.content,p.metadata FROM changed p
        JOIN page_contents c ON c.tenant_id=p.tenant_id AND c.page_id=p.id
      """).rows

    reproject(converted, :doc)
    if length(converted) == 100, do: convert_collaboration_knowledge()
  end

  defp reproject(rows, type) do
    for [tenant, id, xml, metadata] <- rows do
      {:ok, projection} = Ankole.Kernel.vfs_projection(type, xml, metadata)

      repo().query!(
        "UPDATE pages SET vfs_content_empty=$3,vfs_md_size=$4,vfs_md_blake3=$5 WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
        [
          tenant,
          id,
          projection.vfs_content_empty,
          projection.vfs_md_size,
          projection.vfs_md_blake3
        ]
      )
    end
  end

  defp migrate_tenant(tenant) do
    nodes =
      rows(
        """
        WITH RECURSIVE selected AS (
          SELECT p.*, p.system_key='ankole_brain_skills' AS branch FROM pages p
          WHERE p.tenant_id=$1::text::uuid AND
            (p.private_owner_uid IS NOT NULL OR p.system_key IN
              ('ankole_brain','ankole_brain_agents','ankole_brain_skills'))
          UNION ALL
          SELECT p.*, parent.system_key IS DISTINCT FROM 'ankole_brain_agents' AS branch
          FROM pages p JOIN selected parent ON p.parent_id=parent.id
          WHERE p.tenant_id=$1::text::uuid AND p.system_key IS NULL AND
            (parent.branch OR parent.system_key='ankole_brain_agents' OR
             p.name IN ('AGENTS.md','AGENTS.override.md','DESIGN.md','DESIGN.override.md') OR
             (parent.private_owner_uid IS NOT NULL AND p.name='skills'))
        )
        SELECT to_jsonb(p)||jsonb_build_object('xml',coalesce(c.content,'<page />'))
        FROM selected p LEFT JOIN page_contents c ON c.tenant_id=p.tenant_id AND c.page_id=p.id
        """,
        [tenant]
      )

    index = Map.new(nodes, &{&1["id"], &1})
    live = Enum.filter(nodes, &live?(&1, index))
    root = Enum.find(nodes, &(&1["system_key"] == "ankole_brain"))

    if root do
      migrate_contracts(tenant, nodes, live, root)
      skills_root = Enum.find(nodes, &(&1["system_key"] == "ankole_brain_skills"))

      if skills_root do
        for skill <- Enum.filter(live, &(&1["parent_id"] == skills_root["id"])),
            do: migrate_skill(tenant, live, skill)

        purge_pages(tenant, subtree(nodes, skills_root["id"]) |> Enum.map(& &1["id"]))
      end
    end

    migrate_installed(tenant, nodes, live)

    for {slot, markdown} <- [
          {"agents", Ankole.AIAgent.Library.Contracts.default_agents()},
          {"design", Ankole.AIAgent.Library.SourceReader.load_default_design_template()}
        ] do
      {:ok, parsed} = Ankole.Kernel.knowledge_parse(markdown)
      {:ok, canonical} = Ankole.Kernel.knowledge_export(parsed.xml, parsed.metadata)

      put_contract(tenant, nil, slot, "override", parsed.xml, parsed.metadata, %{
        "upstream_base_hash" => Ankole.AIAgent.Library.SourceReader.hash(canonical)
      })
    end

    migrate_legacy_contracts(tenant)
    migrate_unseeded_sources(tenant)
    seed_grants(tenant)
  end

  defp live?(nil, _index), do: true
  defp live?(%{"deleted_at" => deleted}, _index) when not is_nil(deleted), do: false
  defp live?(node, index), do: live?(index[node["parent_id"]], index)

  defp migrate_contracts(tenant, nodes, live, root) do
    live_ids = MapSet.new(live, & &1["id"])

    agent_uids =
      repo().query!("SELECT uid FROM agents WHERE tenant_id=$1::text::uuid", [tenant]).rows
      |> List.flatten()

    agents = Enum.find(nodes, &(&1["system_key"] == "ankole_brain_agents"))

    owners =
      [{nil, root}] ++
        if(agents,
          do: Enum.map(Enum.filter(nodes, &(&1["parent_id"] == agents["id"])), &{&1["name"], &1}),
          else: []
        )

    for {uid, owner} <- owners,
        {slot, filename} <- [{"agents", "AGENTS"}, {"design", "DESIGN"}] do
      children = Enum.filter(nodes, &(&1["parent_id"] == owner["id"]))
      current = Enum.filter(children, &MapSet.member?(live_ids, &1["id"]))
      override = Enum.find(current, &(&1["name"] == filename <> ".override.md"))
      append = Enum.find(current, &(&1["name"] == filename <> ".md"))

      node = override || append

      if node && (is_nil(uid) or uid in agent_uids) do
        put_contract(
          tenant,
          uid,
          slot,
          if(override || is_nil(uid), do: "override", else: "append"),
          node["xml"],
          node["metadata"],
          node["upstream_state"]
        )
      end

      ids =
        Enum.filter(children, &(&1["name"] in [filename <> ".md", filename <> ".override.md"]))
        |> Enum.flat_map(&subtree(nodes, &1["id"]))
        |> Enum.map(& &1["id"])

      purge_pages(tenant, ids)
    end
  end

  defp put_contract(tenant, uid, slot, mode, xml, metadata, upstream) do
    {:ok, markdown} = Ankole.Kernel.knowledge_export(xml, metadata)

    repo().query!(
      """
      INSERT INTO agent_contracts(tenant_id,id,agent_uid,slot,mode,content_xml,content_markdown,metadata,upstream_state)
      VALUES($1::text::uuid,$2::text::uuid,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT DO NOTHING
      """,
      [tenant, uuid(), uid, slot, mode, xml, markdown, metadata, upstream]
    )
  end

  defp migrate_skill(tenant, nodes, node) do
    metadata =
      node["metadata"]
      |> Map.put("name", node["metadata"]["name"] || node["name"])
      |> Map.put(
        "description",
        node["metadata"]["description"] || node["metadata"]["summary"] || node["name"]
      )

    plugin = metadata["agent_plugin_id"]

    kind =
      cond do
        plugin -> "agent_plugin"
        node["upstream_state"]["upstream_base_hash"] -> "builtin"
        true -> "custom"
      end

    id = node["id"]
    {:ok, markdown} = Ankole.Kernel.knowledge_export(node["xml"], metadata)

    name = normalize_slug(metadata["name"])

    legacy =
      rows(
        "SELECT to_jsonb(s) FROM meta_legacy_agent_skills s WHERE tenant_id=$1::text::uuid AND skill_name=$2",
        [tenant, name]
      )

    active =
      repo().query!(
        "SELECT a.uid FROM agents a JOIN principals p ON p.tenant_id=a.tenant_id AND p.uid=a.uid WHERE a.tenant_id=$1::text::uuid AND p.status='active'",
        [tenant]
      ).rows
      |> List.flatten()

    key = if plugin, do: plugin <> ":" <> name, else: name
    defaults = defaults(tenant)
    default = Map.get(defaults, key, Map.get(metadata, "default_enabled", true))

    all =
      default and node["inherit_permissions"] and
        not Enum.any?(legacy, &(&1["agent_uid"] in active and &1["enabled_override"] == false))

    insert_skill(
      tenant,
      id,
      available_slug(tenant, name, "imported", id),
      metadata,
      node["xml"],
      markdown,
      kind,
      plugin,
      all,
      node["upstream_state"]
    )

    for old <- legacy, old["enabled_override"] == true, do: bind(tenant, old["agent_uid"], id)

    unless all do
      for uid <- active do
        old = Enum.find(legacy, &(&1["agent_uid"] == uid))

        enabled =
          if old && is_boolean(old["enabled_override"]),
            do: old["enabled_override"],
            else: default

        if enabled and
             match?({:ok, _}, Ankole.Pod.Pages.Tree.authorize(uid, node["id"], "node_view")),
           do: bind(tenant, uid, id)
      end
    end

    migrate_files(tenant, id, Enum.group_by(nodes, & &1["parent_id"]), node, "")
  end

  defp insert_skill(tenant, id, slug, meta, xml, md, kind, plugin, all, upstream) do
    repo().query!(
      """
      INSERT INTO skills(tenant_id,id,slug,name,description,manifest_xml,manifest_markdown,metadata,source_kind,agent_plugin_id,enabled_for_all,upstream_state)
      VALUES($1::text::uuid,$2::text::uuid,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)
      """,
      [
        tenant,
        id,
        slug,
        meta["name"],
        meta["description"],
        xml,
        md,
        meta,
        kind,
        plugin,
        all,
        upstream
      ]
    )
  end

  defp migrate_files(tenant, skill, nodes, parent, prefix) do
    children = Map.get(nodes, parent["id"], [])
    parents = MapSet.new(Map.keys(nodes))

    # Keep ordinary Markdown names when unambiguous. Use the existing Drive
    # spelling for a knowledge body that conflicts with an attachment or directory.
    occupied =
      children
      |> Enum.filter(&(&1["type"] == "file" or MapSet.member?(parents, &1["id"])))
      |> Enum.map(&Ankole.Kernel.vfs_name(&1["name"], :folder, &1["id"]))
      |> then(&MapSet.new(["SKILL.md" | &1]))

    bodies =
      children
      |> Enum.filter(&(&1["type"] in ["knowledge", "doc"] and &1["vfs_content_empty"] == false))
      |> Enum.frequencies_by(&markdown_name/1)

    for node <- children do
      path = prefix <> Ankole.Kernel.vfs_name(node["name"], :folder, node["id"])

      case node["type"] do
        "file" ->
          path = if path == "SKILL.md", do: "SKILL.attachment-#{node["id"]}.md", else: path

          insert_file(
            tenant,
            skill,
            path,
            node["object_id"],
            node["mode"],
            node["content_type"] || MIME.from_path(path)
          )

        type when type in ["knowledge", "doc"] ->
          {:ok, markdown} =
            if type == "knowledge",
              do: Ankole.Kernel.knowledge_export(node["xml"], node["metadata"]),
              else: Ankole.Kernel.vfs_document_export(node["xml"])

          if node["vfs_content_empty"] == false do
            name = markdown_name(node)

            name =
              if MapSet.member?(occupied, name) or bodies[name] > 1 or
                   String.ends_with?(name, "._awiki.md") or byte_size(name) > 255,
                 do:
                   Ankole.Kernel.vfs_name(node["name"], String.to_existing_atom(type), node["id"]),
                 else: name

            insert_file(
              tenant,
              skill,
              prefix <> name,
              store_bytes(tenant, markdown),
              292,
              "text/markdown"
            )
          end

          migrate_files(tenant, skill, nodes, node, path <> "/")

        type ->
          raise "Skill attachment #{path} has unsupported Page type #{type}; move it outside the package before upgrading"
      end
    end
  end

  defp markdown_name(node) do
    name = node["name"]
    if String.ends_with?(name, ".md"), do: name, else: name <> ".md"
  end

  defp insert_file(tenant, skill, path, object, mode, content_type) do
    repo().query!(
      """
      INSERT INTO skill_files(tenant_id,id,skill_id,relative_path,object_id,mode,content_type)
      VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5::text::uuid,$6,$7)
      """,
      [
        tenant,
        uuid(),
        skill,
        path,
        object,
        if(Bitwise.band(mode, 73) > 0, do: 365, else: 292),
        content_type
      ]
    )
  end

  defp store_bytes(tenant, bytes) do
    id = uuid()
    key = "tenants/#{tenant}/objects/#{id}"
    {:ok, stored} = Ankole.ObjectStore.write_stream(key, [bytes])

    hash =
      if byte_size(stored.sha256) == 64,
        do: Base.decode16!(stored.sha256, case: :mixed),
        else: stored.sha256

    repo().query!(
      "INSERT INTO file_objects(tenant_id,id,storage_key,sha256,size,created_at,completed_at) VALUES($1::text::uuid,$2::text::uuid,$3,$4,$5,now(),now())",
      [tenant, id, key, hash, stored.size]
    )

    id
  end

  # Reads one column so that file_objects columns from later migrations do not matter here.
  defp read_object(tenant, id) do
    [key] =
      rows(
        "SELECT storage_key FROM file_objects WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
        [
          tenant,
          id
        ]
      )

    Ankole.ObjectStore.read(key)
  end

  defp migrate_installed(tenant, nodes, live) do
    for old <-
          rows(
            "SELECT to_jsonb(s) FROM meta_legacy_agent_skills s WHERE tenant_id=$1::text::uuid AND source_kind='installed'",
            [tenant]
          ) do
      root = Enum.find(live, &(&1["private_owner_uid"] == old["agent_uid"]))

      with %{} <- root,
           %{} = dir <- child(live, root["id"], "skills"),
           %{} = package <- child(live, dir["id"], old["relative_path"]),
           %{} = manifest <- child(live, package["id"], "SKILL.md") do
        {:ok, bytes} = read_object(tenant, manifest["object_id"])
        {:ok, parsed} = Ankole.Kernel.knowledge_parse(bytes)

        metadata =
          parsed.metadata
          |> Map.put("name", parsed.metadata["name"] || old["skill_name"])
          |> Map.put("description", parsed.metadata["description"] || old["skill_name"])

        {:ok, md} = Ankole.Kernel.knowledge_export(parsed.xml, metadata)
        slug = available_slug(tenant, old["skill_name"], old["agent_uid"], old["id"])
        id = uuid()
        insert_skill(tenant, id, slug, metadata, parsed.xml, md, "custom", nil, false, %{})
        bind(tenant, old["agent_uid"], id)

        migrate_files(
          tenant,
          id,
          live |> Enum.reject(&(&1["id"] == manifest["id"])) |> Enum.group_by(& &1["parent_id"]),
          package,
          ""
        )

        purge_pages(tenant, subtree(nodes, package["id"]) |> Enum.map(& &1["id"]))
      else
        _ ->
          root = Enum.find(nodes, &(&1["private_owner_uid"] == old["agent_uid"]))
          dir = root && child(nodes, root["id"], "skills")
          package = dir && child(nodes, dir["id"], old["relative_path"])
          manifest = package && child(nodes, package["id"], "SKILL.md")

          if Enum.any?([root, dir, package, manifest], &(&1 && &1["deleted_at"])) do
            if package,
              do: purge_pages(tenant, subtree(nodes, package["id"]) |> Enum.map(& &1["id"]))
          else
            IO.warn(
              "Installed Skill #{old["agent_uid"]}/#{old["skill_name"]} has no SKILL.md; its files remain in the private Drive for repair and import"
            )
          end
      end
    end
  end

  defp available_slug(tenant, name, uid, id) do
    candidates =
      Enum.map([name, uid <> "-" <> name, "imported-" <> to_string(id)], &normalize_slug/1)

    candidates
    |> Stream.concat(
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&("imported-" <> to_string(id) <> "-" <> to_string(&1)))
    )
    |> Enum.find(fn slug ->
      repo().query!("SELECT 1 FROM skills WHERE tenant_id=$1::text::uuid AND slug=$2", [
        tenant,
        slug
      ]).rows == []
    end)
  end

  defp normalize_slug(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim_leading("-")
      |> String.trim_leading(".")
      |> String.trim_leading("_")
      |> String.slice(0, 96)

    if Regex.match?(~r/^[a-z0-9]/, slug), do: slug, else: "imported"
  end

  defp migrate_legacy_contracts(tenant) do
    if repo().query!("SELECT to_regclass('agent_library_container_entries')").rows != [[nil]] do
      alias Ankole.AIAgent.Library.SourceReader

      defaults = %{
        "SOUL.md" => SourceReader.load_default_soul_template(),
        "MISSION.md" => SourceReader.load_default_mission_template(),
        "DESIGN.md" => SourceReader.load_default_design_template(),
        "ConfidentialityPolicy.md" => SourceReader.load_default_confidentiality_policy_template()
      }

      for [uid, type] <-
            repo().query!("SELECT uid,type FROM agents WHERE tenant_id=$1::text::uuid", [tenant]).rows do
        entries =
          repo().query!(
            "SELECT path,content FROM agent_library_container_entries WHERE tenant_id=$1::text::uuid AND agent_uid=$2 AND deleted_at IS NULL",
            [tenant, uid]
          ).rows
          |> Map.new(fn [k, v] -> {k, v} end)

        documents = Map.merge(defaults, entries)

        custom_agents =
          Enum.any?(
            ~w(SOUL.md MISSION.md ConfidentialityPolicy.md),
            &(documents[&1] != defaults[&1])
          )

        if type == "personal_assistant" or custom_agents do
          confidentiality =
            if documents["ConfidentialityPolicy.md"] == defaults["ConfidentialityPolicy.md"],
              do: "",
              else: documents["ConfidentialityPolicy.md"]

          agents =
            [documents["SOUL.md"], documents["MISSION.md"], confidentiality]
            |> Enum.reject(&(String.trim(&1) == ""))
            |> Enum.join("\n\n")

          legacy_contract(tenant, uid, "agents", agents)
        end

        if documents["DESIGN.md"] != defaults["DESIGN.md"],
          do: legacy_contract(tenant, uid, "design", documents["DESIGN.md"])
      end
    end
  end

  defp legacy_contract(tenant, uid, slot, markdown) do
    {:ok, parsed} = Ankole.Kernel.knowledge_parse(markdown)
    put_contract(tenant, uid, slot, "override", parsed.xml, parsed.metadata, %{})
  end

  # Direct upgrades have no shared Skill pages yet. Seed shipped packages while
  # the old per-agent overrides and tenant defaults are still available.
  defp migrate_unseeded_sources(tenant) do
    {:ok, sources} = Ankole.AIAgent.Library.shipped_skill_sources()

    for source <- sources,
        repo().query!("SELECT 1 FROM skills WHERE tenant_id=$1::text::uuid AND slug=$2", [
          tenant,
          source.name
        ]).rows == [] do
      manifest = Enum.find(source.files, &(&1.path == "SKILL.md"))
      {:ok, parsed} = Ankole.Kernel.knowledge_parse(manifest.content)
      {:ok, markdown} = Ankole.Kernel.knowledge_export(parsed.xml, parsed.metadata)

      state = %{
        "upstream_base_hash" => source.source_hash,
        "content_hash" => Ankole.AIAgent.Library.SourceReader.hash(markdown),
        "files" =>
          Map.new(Enum.reject(source.files, &(&1.path == "SKILL.md")), fn file ->
            {file.path,
             %{
               "sha256" => :crypto.hash(:sha256, file.content) |> Base.encode16(case: :lower),
               "mode" => file.mode
             }}
          end)
      }

      legacy =
        rows(
          "SELECT to_jsonb(s) FROM meta_legacy_agent_skills s WHERE tenant_id=$1::text::uuid AND skill_name=$2 AND source_kind<>'installed'",
          [tenant, source.name]
        )

      active =
        repo().query!(
          "SELECT a.uid FROM agents a JOIN principals p ON p.tenant_id=a.tenant_id AND p.uid=a.uid WHERE a.tenant_id=$1::text::uuid AND p.status='active'",
          [tenant]
        ).rows
        |> List.flatten()

      plugin = source.metadata["agent_plugin_id"]
      key = if plugin, do: plugin <> ":" <> source.name, else: source.name
      default = Map.get(defaults(tenant), key, source.default_enabled)

      all =
        default and
          not Enum.any?(legacy, &(&1["agent_uid"] in active and &1["enabled_override"] == false))

      id = uuid()

      insert_skill(
        tenant,
        id,
        source.name,
        parsed.metadata,
        parsed.xml,
        markdown,
        if(plugin, do: "agent_plugin", else: "builtin"),
        plugin,
        all,
        state
      )

      for old <- legacy, old["enabled_override"] == true, do: bind(tenant, old["agent_uid"], id)

      unless all do
        for uid <- active do
          old = Enum.find(legacy, &(&1["agent_uid"] == uid))

          enabled =
            if old && is_boolean(old["enabled_override"]),
              do: old["enabled_override"],
              else: default

          if enabled, do: bind(tenant, uid, id)
        end
      end

      for file <- source.files,
          file.path != "SKILL.md",
          do:
            insert_file(
              tenant,
              id,
              file.path,
              store_bytes(tenant, file.content),
              file.mode,
              MIME.from_path(file.path)
            )
    end
  end

  defp bind(tenant, uid, skill) do
    repo().query!(
      "INSERT INTO agent_skills(tenant_id,agent_uid,skill_id) VALUES($1::text::uuid,$2,$3::text::uuid) ON CONFLICT DO NOTHING",
      [tenant, uid, skill]
    )
  end

  defp defaults(tenant) do
    global =
      repo().query!(
        "SELECT value->'value' FROM site_app_configurations WHERE key='ai_agent.library.skill_defaults'",
        []
      ).rows

    local =
      repo().query!(
        "SELECT value->'value' FROM app_configurations WHERE tenant_id=$1::text::uuid AND key='ai_agent.library.skill_defaults'",
        [tenant]
      ).rows

    case local ++ global do
      [[value] | _] when is_map(value) -> value
      _ -> %{}
    end
  end

  defp seed_grants(tenant) do
    for [group] <-
          repo().query!(
            "SELECT id::text FROM principal_groups WHERE tenant_id=$1::text::uuid AND name='all_humans'",
            [tenant]
          ).rows,
        action <- ["update", "delete"] do
      repo().query!(
        """
        INSERT INTO permission_grants(tenant_id,id,group_id,resource_pattern,action,inserted_at,updated_at)
        SELECT $1::text::uuid,$2::text::uuid,$3::text::uuid,'tenant_console:custom_skills',$4,now(),now()
        WHERE NOT EXISTS(SELECT 1 FROM permission_grants WHERE tenant_id=$1::text::uuid AND group_id=$3::text::uuid AND resource_pattern='tenant_console:custom_skills' AND action=$4)
        """,
        [tenant, uuid(), group, action]
      )
    end
  end

  defp purge_pages(_tenant, []), do: :ok

  defp purge_pages(tenant, ids) do
    # Page foreign keys cascade histories, comments, aliases, chunks and graph edges.
    repo().query!(
      "DELETE FROM pages WHERE tenant_id=$1::text::uuid AND id=ANY($2::text[]::uuid[])",
      [tenant, ids]
    )
  end

  defp subtree(nodes, id),
    do:
      Enum.filter(nodes, &(&1["id"] == id)) ++
        (Enum.filter(nodes, &(&1["parent_id"] == id)) |> Enum.flat_map(&subtree(nodes, &1["id"])))

  defp child(nodes, id, name),
    do: Enum.find(nodes, &(&1["parent_id"] == id and &1["name"] == name))

  defp rows(sql, params), do: repo().query!(sql, params).rows |> Enum.map(&hd/1)
  defp uuid, do: Ankole.Ecto.UUIDv7.autogenerate()

  def down,
    do: raise(Ecto.MigrationError, "Restore a database backup to reverse Meta Ankole separation")
end
