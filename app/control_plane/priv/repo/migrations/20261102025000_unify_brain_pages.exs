defmodule Ankole.Repo.Migrations.UnifyBrainPages do
  use Ecto.Migration

  @references [
    {"brain_claims", "object_slug", "subject_page_id"},
    {"brain_timelines", "object_slug", "subject_page_id"},
    {"brain_timelines", "event_object_slug", "event_page_id"},
    {"brain_links", "from_object_slug", "from_page_id"},
    {"brain_links", "to_object_slug", "to_page_id"},
    {"brain_links", "origin_object_slug", "origin_page_id"},
    {"brain_tags", "object_slug", "subject_page_id"},
    {"brain_object_aliases", "object_slug", "subject_page_id"},
    {"brain_slug_aliases", "canonical_slug", "canonical_page_id"}
  ]

  def up do
    for {table, _, field} <- @references,
        do: execute("ALTER TABLE #{table} ADD COLUMN #{field} uuid")

    for table <- ~w(brain_claims brain_timelines),
        do: execute("ALTER TABLE #{table} ADD COLUMN source_node_id uuid")

    execute("ALTER TABLE brain_sources ADD COLUMN default_source_node_id uuid")
    execute("DELETE FROM brain_chunks")
    execute("ALTER TABLE brain_chunks DROP CONSTRAINT brain_chunks_object_id_fkey")
    execute("ALTER TABLE brain_chunks RENAME COLUMN object_id TO page_id")
    execute("ALTER TABLE brain_chunks DROP COLUMN audience_scope")
    execute("ALTER TABLE brain_chunks ADD COLUMN source_node_id uuid NOT NULL")
    execute("ALTER TABLE brain_chunks ADD COLUMN page_revision bigint NOT NULL DEFAULT 0")
    execute("ALTER TABLE brain_chunks ADD COLUMN chunking_signature text")

    execute(
      "ALTER TABLE brain_chunks ADD CONSTRAINT brain_chunks_page_id_fkey FOREIGN KEY (tenant_id,page_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE"
    )

    execute(
      "ALTER TABLE brain_chunks ADD CONSTRAINT brain_chunks_source_node_id_fkey FOREIGN KEY (tenant_id,source_node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE"
    )

    # Skill discovery records are rebuildable catalog projections. The complete
    # skill directories are reconciled by Agent Library into their Pod owner.
    execute(
      "DELETE FROM brain_merge_suggestions WHERE a_slug LIKE 'lazyload-agent-skills/%' OR b_slug LIKE 'lazyload-agent-skills/%'"
    )

    execute(
      "DELETE FROM brain_objects WHERE slug LIKE 'lazyload-agent-skills/%' OR type='agent-skills'"
    )

    execute("DELETE FROM brain_schema_types WHERE name='agent-skills'")
    execute("DELETE FROM app_configurations WHERE key='brain.soft_delete_retention_hours'")
    execute("DELETE FROM site_app_configurations WHERE key='brain.soft_delete_retention_hours'")
    flush()
    {:ok, general} = Ankole.Brain.SchemaPacks.load_seed("general")

    repo().query!(
      "UPDATE brain_schema_packs SET version=$1,manifest=$2::jsonb,content_hash=$3 WHERE name='general'",
      [general.manifest["version"], general.manifest, general.content_hash]
    )

    execute(page_view())
    flush()

    repo().query!(
      "CREATE TEMP TABLE brain_page_migration (tenant_id uuid, slug text, page_id uuid, scope text, PRIMARY KEY(tenant_id,slug,scope)) ON COMMIT DROP"
    )

    for [tenant_id] <- repo().query!("SELECT id::text FROM tenants").rows do
      Ankole.Repo.with_tenant(tenant_id, fn -> migrate_tenant(tenant_id) end)
    end

    for {table, previous, field} <- @references do
      execute("""
      UPDATE #{table} r SET #{field}=m.page_id FROM brain_page_migration m
      WHERE m.tenant_id=r.tenant_id AND m.slug=r.#{previous} AND m.scope='world'
      """)
    end

    flush()

    for [tenant_id] <- repo().query!("SELECT id::text FROM tenants").rows do
      Ankole.Repo.with_tenant(tenant_id, fn -> migrate_sources(tenant_id) end)
    end

    execute("""
    UPDATE brain_merge_suggestions s SET a_slug=LEAST(a.page_id::text,b.page_id::text),
      b_slug=GREATEST(a.page_id::text,b.page_id::text)
    FROM brain_page_migration a,brain_page_migration b
    WHERE s.tenant_id=a.tenant_id AND s.tenant_id=b.tenant_id AND a.scope='world' AND b.scope='world'
      AND s.a_slug=a.slug AND s.b_slug=b.slug
    """)

    # All relationships now use the immutable Drive identity. Dropping the old
    # columns also removes their path-based indexes and foreign keys.
    for {table, previous, field} <- @references do
      execute("ALTER TABLE #{table} DROP COLUMN #{previous} CASCADE")

      execute(
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_#{field}_fkey FOREIGN KEY (tenant_id,#{field}) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE"
      )
    end

    for {table, field} <- [
          {"brain_links", "from_page_id"},
          {"brain_links", "to_page_id"},
          {"brain_tags", "subject_page_id"},
          {"brain_object_aliases", "subject_page_id"},
          {"brain_slug_aliases", "canonical_page_id"}
        ] do
      execute("ALTER TABLE #{table} ALTER COLUMN #{field} SET NOT NULL")
    end

    for table <- ~w(brain_claims brain_timelines) do
      execute("ALTER TABLE #{table} DROP COLUMN audience_scope CASCADE")
      execute("ALTER TABLE #{table} ALTER COLUMN source_node_id SET NOT NULL")

      execute(
        "ALTER TABLE #{table} ADD CONSTRAINT #{table}_source_node_id_fkey FOREIGN KEY (tenant_id,source_node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE CASCADE"
      )
    end

    execute("ALTER TABLE brain_sources DROP COLUMN default_audience_scope CASCADE")

    execute(
      "ALTER TABLE brain_sources ADD CONSTRAINT brain_sources_default_source_node_id_fkey FOREIGN KEY (tenant_id,default_source_node_id) REFERENCES drive_nodes(tenant_id,id) ON DELETE RESTRICT"
    )

    execute("ALTER TABLE brain_links DROP CONSTRAINT IF EXISTS brain_links_source_shape")

    execute(
      "CREATE UNIQUE INDEX brain_links_dedup_key ON brain_links (tenant_id,from_page_id,to_page_id,link_type,link_source,origin_page_id) NULLS NOT DISTINCT"
    )

    execute(
      "CREATE UNIQUE INDEX brain_tags_object_tag_key ON brain_tags (tenant_id,subject_page_id,tag)"
    )

    execute(
      "CREATE UNIQUE INDEX brain_object_aliases_dedup_key ON brain_object_aliases (tenant_id,alias_norm,subject_page_id)"
    )

    execute(
      "CREATE UNIQUE INDEX brain_timelines_dedup_key ON brain_timelines (tenant_id,subject_page_id,source_node_id,date,summary,provenance) NULLS NOT DISTINCT"
    )

    execute(
      "CREATE UNIQUE INDEX brain_timelines_event_dedup_key ON brain_timelines (tenant_id,event_page_id,source_node_id,date) WHERE event_page_id IS NOT NULL"
    )

    execute(
      "CREATE INDEX brain_claims_source_subject_idx ON brain_claims (tenant_id,source_node_id,subject_page_id)"
    )

    execute("DROP TABLE brain_object_versions")
    execute("DROP TABLE brain_objects")
    flush()

    # Derived chunks and links are rebuilt after the Page ownership migration.
  end

  def down,
    do:
      raise(
        Ecto.MigrationError,
        "Knowledge unification preserves content in Pod; restore a backup to reverse it"
      )

  defp migrate_tenant(tenant_id) do
    {:ok, namespace} = legacy_namespace()

    for [id] <-
          repo().query!("SELECT id::text FROM conversations WHERE tenant_id=$1::text::uuid", [
            tenant_id
          ]).rows do
      {:ok, _root} = legacy_conversation_root(id)
    end

    rows =
      repo().query!(
        "SELECT to_jsonb(o) FROM brain_objects o WHERE tenant_id=$1::text::uuid ORDER BY length(slug),slug",
        [tenant_id]
      ).rows

    for [object] <- rows do
      {parents, [name]} = object["slug"] |> String.split("/", trim: true) |> Enum.split(-1)

      parent =
        Enum.reduce(parents, namespace.root, fn name, parent ->
          case legacy_child(parent.id, name) do
            {:ok, %{kind: :file}} ->
              raise("legacy knowledge parent is a file")

            {:ok, node} ->
              node

            {:error, :not_found} ->
              {:ok, node} = legacy_child_create(parent.id, name, :folder)
              node
          end
        end)

      {:ok, page} = legacy_child_create(parent.id, name, :knowledge, id: object["id"])
      remember(tenant_id, object["slug"], "world", page.id)

      versions =
        repo().query!(
          "SELECT to_jsonb(v) FROM brain_object_versions v WHERE tenant_id=$1::text::uuid AND object_id=$2::text::uuid ORDER BY snapshot_at,id",
          [tenant_id, object["id"]]
        ).rows
        |> List.flatten()

      mixed? =
        Enum.any?([object | versions], &Regex.match?(~r/\{%\s*audience\s/, &1["body"] || ""))

      scopes = segments(object["body"]) |> Map.keys()

      pages =
        Map.new(scopes, fn scope ->
          node = if scope == "world", do: page, else: restricted_page(page, scope)
          remember(tenant_id, object["slug"], scope, node.id)
          {scope, node}
        end)
        |> Map.put("world", page)

      metadata =
        Map.merge(business_metadata(object, object["meta"]), %{
          "entity_type" => object["type"],
          "subtype" => object["subtype"]
        })

      tags =
        repo().query!(
          "SELECT tag FROM brain_tags WHERE tenant_id=$1::text::uuid AND object_slug=$2",
          [tenant_id, object["slug"]]
        ).rows
        |> List.flatten()

      aliases =
        repo().query!(
          "SELECT alias_norm FROM brain_object_aliases WHERE tenant_id=$1::text::uuid AND object_slug=$2",
          [tenant_id, object["slug"]]
        ).rows
        |> List.flatten()

      metadata =
        metadata
        |> Map.put("tags", Enum.uniq(tags ++ Map.get(metadata, "tags", [])))
        |> Map.put("aliases", Enum.uniq(aliases ++ Map.get(metadata, "aliases", [])))

      Enum.each(pages, fn {scope, node} ->
        body = Map.get(segments(object["body"]), scope, "")

        put_content(
          node,
          body,
          metadata,
          object["title"],
          object["created_at"],
          object["updated_at"]
        )

        history =
          if mixed?, do: [Map.put(object, "snapshot_at", object["updated_at"])], else: versions

        Enum.with_index(history, 1)
        |> Enum.each(fn {version, revision} ->
          markdown = if mixed?, do: body, else: version["body"]
          {:ok, parsed} = Ankole.Kernel.knowledge_parse(markdown)

          repo().query!(
            """
            INSERT INTO page_snapshots(id,tenant_id,page_id,revision,title,metadata,content,author,
              document_updated_at,created_at,reason)
            VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5,$6::jsonb,$7,$8,$9,$9,$10)
            """,
            [
              Ankole.Ecto.UUIDv7.autogenerate(),
              tenant_id,
              node.id,
              revision,
              object["title"],
              business_metadata(object, version["meta"]),
              parsed.xml,
              version["author"] || to_string(author()),
              datetime(version["snapshot_at"]),
              if(mixed?, do: "baseline", else: "checkpoint")
            ]
          )
        end)

        repo().query!(
          "UPDATE pages SET revision=$3 WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
          [tenant_id, node.id, if(mixed?, do: 1, else: length(versions) + 1)]
        )
      end)

      if object["deleted_at"],
        do: legacy_update_anchor(page, :trash, %{deleted_at: datetime(object["deleted_at"])})

      if source_id = object["managed_by_source_id"] do
        legacy = object["meta"] || %{}

        state =
          legacy
          |> Map.take(["source_revision", "conversation_id"])
          |> Map.put("source_id", source_id)

        state =
          if legacy["audience_scope"],
            do: Map.put(state, "source_node_id", source_fallback(legacy["audience_scope"], nil)),
            else: state

        repo().query!(
          "UPDATE pages SET upstream_state=$3::jsonb WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
          [tenant_id, page.id, state]
        )
      end

      protect_assistant(page, object["slug"])
    end
  end

  defp business_metadata(%{"managed_by_source_id" => id}, metadata) when not is_nil(id),
    do:
      Map.drop(metadata || %{}, [
        "source_revision",
        "conversation_id",
        "audience_scope",
        "source_node_id"
      ])

  defp business_metadata(_object, metadata), do: metadata || %{}

  defp migrate_sources(tenant_id) do
    for table <- ~w(brain_claims brain_timelines) do
      for [row] <-
            repo().query!("SELECT to_jsonb(r) FROM #{table} r WHERE tenant_id=$1::text::uuid", [
              tenant_id
            ]).rows do
        source = source_node(row["audience_scope"], row["object_slug"], row["conversation_id"])

        repo().query!(
          "UPDATE #{table} SET source_node_id=$3::text::uuid WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
          [tenant_id, row["id"], source]
        )
      end
    end

    for [id, scope] <-
          repo().query!(
            "SELECT id::text,default_audience_scope FROM brain_sources WHERE tenant_id=$1::text::uuid",
            [tenant_id]
          ).rows do
      node = if scope, do: source_node(scope, nil, nil), else: nil

      repo().query!(
        "UPDATE brain_sources SET default_source_node_id=$3::text::uuid WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
        [tenant_id, id, node]
      )
    end
  end

  defp source_node(_scope, nil, conversation_id) when is_binary(conversation_id) do
    {:ok, node} = legacy_conversation_root(conversation_id)
    node.id
  end

  defp source_node(scope, slug, conversation_id) do
    known =
      if slug,
        do:
          repo().query!(
            "SELECT page_id::text FROM brain_page_migration WHERE tenant_id=$1::text::uuid AND slug=$2 AND scope=$3",
            [Ankole.Repo.tenant_id!(), slug, scope]
          ).rows,
        else: []

    case known do
      [[id]] -> id
      [] -> source_fallback(scope, conversation_id)
    end
  end

  defp source_fallback("world", _) do
    {:ok, root} = legacy_brain_root()
    root.id
  end

  defp source_fallback("principal:" <> uid = scope, _) do
    case legacy_principal(uid) do
      {:ok, %{type: :system}} ->
        source_container(scope)

      {:ok, _} ->
        {:ok, node} = legacy_private_root(uid)
        node.id
    end
  end

  defp source_fallback("group:" <> _ = scope, conversation) when is_binary(conversation) do
    {:ok, node} = legacy_conversation_root(conversation)
    restricted_page(node, scope).id
  end

  defp source_fallback(scope, _), do: source_container(scope)

  defp source_container(scope) do
    {:ok, root} = legacy_brain_root()
    {:ok, sources} = legacy_child_create(root.id, "sources", :folder)
    node = restricted_page(sources, scope)
    node.id
  end

  defp restricted_page(parent, scope) do
    tenant = Ankole.Repo.tenant_id!()
    key = "@source/" <> parent.id

    case repo().query!(
           "SELECT page_id::text FROM brain_page_migration WHERE tenant_id=$1::text::uuid AND slug=$2 AND scope=$3",
           [tenant, key, scope]
         ).rows do
      [[id]] ->
        {:ok, node} = legacy_fetch(id)
        node

      [] ->
        base = scope |> String.split(":", parts: 2) |> List.last()
        {:ok, path} = legacy_path(parent)

        parent_slug =
          path
          |> Enum.reject(&is_nil(&1.parent_id))
          |> Enum.map_join("/", & &1.name)
          |> String.replace_prefix("AnkoleBrain/", "")

        name =
          Stream.iterate(1, &(&1 + 1))
          |> Enum.find_value(fn suffix ->
            candidate = if suffix == 1, do: base, else: "#{base} (#{suffix})"

            legacy =
              repo().query!(
                "SELECT 1 FROM brain_objects WHERE tenant_id=$1::text::uuid AND slug=$2",
                [tenant, parent_slug <> "/" <> candidate]
              ).rows

            if legacy == [] and legacy_child(parent.id, candidate) == {:error, :not_found},
              do: candidate
          end)

        {:ok, node} =
          legacy_child_create(parent.id, name, :knowledge, inherit_permissions: false)

        grant_scope(node, scope)
        now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        put_content(node, "", %{}, name, now, now)
        remember(tenant, key, scope, node.id)
        node
    end
  end

  defp grant_scope(node, "group:" <> name) do
    {:ok, group} = legacy_group(name)
    :ok = legacy_role(%{group_id: group.id}, "drive:**:#{node.id}:**", "view")
  end

  defp grant_scope(node, "principal:" <> uid),
    do: legacy_role(%{principal_uid: uid}, "drive:**:#{node.id}:**", "view")

  defp protect_assistant(node, "agents/" <> uid) do
    case repo().query!(
           "SELECT owner_principal_uid FROM agents WHERE tenant_id=$1::text::uuid AND uid=$2 AND type='personal_assistant'",
           [Ankole.Repo.tenant_id!(), uid]
         ).rows do
      [[owner]] ->
        {:ok, _} = legacy_update_anchor(node, :sharing, %{inherit_permissions: false})
        :ok = legacy_role(%{principal_uid: uid}, "drive:**:#{node.id}:**", "view")
        :ok = legacy_role(%{principal_uid: owner}, "drive:**:#{node.id}:**", "manage")

      [] ->
        :ok
    end
  end

  defp protect_assistant(_, _), do: :ok

  defp put_content(node, body, metadata, title, created, updated) do
    {:ok, parsed} = Ankole.Kernel.knowledge_parse(body)
    at = datetime(updated)

    repo().query!(
      """
      INSERT INTO page_contents(tenant_id,page_id,content,plain_text,updated_by,updated_at,contributors)
      VALUES($1::text::uuid,$2::text::uuid,$3,$4,$5,$6,ARRAY[]::text[])
      ON CONFLICT(page_id) DO UPDATE SET content=EXCLUDED.content,plain_text=EXCLUDED.plain_text,
        updated_by=EXCLUDED.updated_by,updated_at=EXCLUDED.updated_at
      """,
      [Ankole.Repo.tenant_id!(), node.id, parsed.xml, parsed.plain_text, to_string(author()), at]
    )

    repo().query!(
      """
      UPDATE pages SET title=$3,metadata=$4::jsonb,updated_at=$5,revision=revision+1
      WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid
      """,
      [Ankole.Repo.tenant_id!(), node.id, title, metadata, at]
    )

    repo().query!(
      "UPDATE drive_nodes SET created_at=$3,updated_at=$4 WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
      [Ankole.Repo.tenant_id!(), node.id, datetime(created), at]
    )
  end

  defp remember(tenant, slug, scope, id),
    do:
      repo().query!(
        "INSERT INTO brain_page_migration VALUES ($1::text::uuid,$2,$3::text::uuid,$4) ON CONFLICT DO NOTHING",
        [tenant, slug, id, scope]
      )

  defp author,
    do: Ankole.ActorRef.from_principal(%{tenant_id: Ankole.Repo.tenant_id!(), uid: "system"})

  defp datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} ->
        datetime

      {:error, :missing_offset} ->
        NaiveDateTime.from_iso8601!(value) |> DateTime.from_naive!("Etc/UTC")
    end
  end

  # Migration-only decoder. Stored Brain documents prohibit nested audience
  # blocks. Fenced and inline code are literal and never become ACL markers.
  defp segments(body) do
    tokens =
      Regex.split(
        ~r/(```[^\n]*\n[\s\S]*?\n```|~~~[^\n]*\n[\s\S]*?\n~~~|`+[^`]*`+|\{%\s*audience\s+scope="[^"]+"\s*%\}|\{%\s*\/audience\s*%\})/u,
        body || "",
        include_captures: true
      )

    {parts, "world"} =
      Enum.reduce(tokens, {%{}, "world"}, fn text, {parts, scope} ->
        cond do
          Regex.match?(~r/^\{%\s*audience\s/, text) ->
            [_, next] = Regex.run(~r/scope="([^"]+)"/, text)
            if scope != "world", do: raise("nested legacy audience block")
            {parts, next}

          Regex.match?(~r/^\{%\s*\/audience\s*%\}$/, text) ->
            {parts, "world"}

          true ->
            {Map.update(parts, scope, text, &(&1 <> text)), scope}
        end
      end)

    parts
  end

  # These helpers deliberately use the schema at this migration version. They
  # must not call live Page resources whose tables can change in later releases.
  defp legacy_query(where, args) do
    case repo().query!(
           "SELECT to_jsonb(n) FROM drive_nodes n WHERE n.tenant_id=$1::text::uuid AND " <> where,
           [Ankole.Repo.tenant_id!() | args]
         ).rows do
      [[row]] ->
        {:ok,
         %{
           id: row["id"],
           parent_id: row["parent_id"],
           name: row["name"],
           kind: String.to_existing_atom(row["kind"]),
           acl_anchor_id: row["acl_anchor_id"],
           inherit_permissions: row["inherit_permissions"],
           system_key: row["system_key"]
         }}

      [] ->
        {:error, :not_found}
    end
  end

  defp legacy_fetch(id), do: legacy_query("n.id=$2::text::uuid", [id])

  defp legacy_child(parent, name),
    do:
      legacy_query("n.parent_id=$2::text::uuid AND n.name=$3 AND n.deleted_at IS NULL", [
        parent,
        name
      ])

  defp legacy_brain_root, do: legacy_query("n.system_key='ankole_brain'", [])

  defp legacy_root(name, owner, conversation) do
    case legacy_query(
           "n.parent_id IS NULL AND n.private_owner_uid IS NOT DISTINCT FROM $2::text AND n.conversation_id IS NOT DISTINCT FROM $3::text::uuid",
           [owner, conversation]
         ) do
      {:ok, _} = found ->
        found

      {:error, :not_found} ->
        id = Ankole.Ecto.UUIDv7.autogenerate()

        repo().query!(
          """
          INSERT INTO drive_nodes(tenant_id,id,name,kind,private_owner_uid,conversation_id,acl_anchor_id,
            inherit_permissions,has_local_acl,mode,created_at,updated_at)
          VALUES($1::text::uuid,$2::text::uuid,$3,'folder',$4,$5::text::uuid,$2::text::uuid,true,false,420,now(),now())
          """,
          [Ankole.Repo.tenant_id!(), id, name, owner, conversation]
        )

        legacy_fetch(id)
    end
  end

  defp legacy_conversation_root(id), do: legacy_root("Conversation", nil, id)

  defp legacy_private_root(uid) do
    with {:ok, root} <- legacy_root("Private", uid, nil),
         :ok <- legacy_role(%{principal_uid: uid}, "drive:private:#{uid}:**", "manage"),
         do: {:ok, root}
  end

  defp legacy_namespace do
    {:ok, public} = legacy_root("Space", nil, nil)
    {:ok, root} = legacy_system(public.id, "AnkoleBrain", "ankole_brain", false)
    {:ok, root} = legacy_update_anchor(root, :sharing, %{inherit_permissions: false})
    {:ok, agents} = legacy_system(root.id, "agents", "ankole_brain_agents", true)
    {:ok, skills} = legacy_system(root.id, "skills", "ankole_brain_skills", true)

    for {name, role} <- [{"all_humans", "view"}, {"all_agents", "view"}, {"pod_admin", "manage"}] do
      {:ok, group} = legacy_group(name)
      :ok = legacy_role(%{group_id: group.id}, "drive:**:#{root.id}:**", role)
    end

    {:ok, %{root: root, agents: agents, skills: skills}}
  end

  defp legacy_system(parent, name, key, inherit) do
    case legacy_query("n.system_key=$2", [key]) do
      {:ok, _} = found ->
        found

      {:error, :not_found} ->
        {:ok, node} = legacy_child_create(parent, name, :folder, inherit_permissions: inherit)

        repo().query!(
          "UPDATE drive_nodes SET system_key=$3 WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
          [Ankole.Repo.tenant_id!(), node.id, key]
        )

        legacy_fetch(node.id)
    end
  end

  defp legacy_child_create(parent, name, kind, attrs \\ []) do
    case legacy_child(parent, name) do
      {:ok, %{kind: ^kind}} = found ->
        found

      {:ok, _} ->
        raise "legacy knowledge path has incompatible content"

      {:error, :not_found} ->
        {:ok, p} = legacy_fetch(parent)
        id = Keyword.get_lazy(attrs, :id, &Ankole.Ecto.UUIDv7.autogenerate/0)
        inherit = Keyword.get(attrs, :inherit_permissions, true)

        repo().query!(
          """
          INSERT INTO drive_nodes(tenant_id,id,parent_id,name,kind,inherit_permissions,has_local_acl,
            acl_anchor_id,parent_anchor_id,mode,created_by,created_at,updated_at)
          VALUES($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5,$6,false,$7::text::uuid,$8::text::uuid,420,$9,now(),now())
          """,
          [
            Ankole.Repo.tenant_id!(),
            id,
            parent,
            name,
            to_string(kind),
            inherit,
            if(inherit, do: p.acl_anchor_id, else: id),
            if(inherit, do: nil, else: p.acl_anchor_id),
            to_string(author())
          ]
        )

        repo().query!(
          """
          INSERT INTO pages(id,tenant_id,title,revision,children_view,metadata,upstream_state,created_at,updated_at)
          VALUES($1::text::uuid,$2::text::uuid,$3,0,'{}','{}','{}',now(),now())
          """,
          [id, Ankole.Repo.tenant_id!(), name]
        )

        legacy_fetch(id)
    end
  end

  defp legacy_path(%{parent_id: nil} = node), do: {:ok, [node]}

  defp legacy_path(node) do
    {:ok, parent} = legacy_fetch(node.parent_id)
    {:ok, path} = legacy_path(parent)
    {:ok, path ++ [node]}
  end

  defp legacy_principal(uid) do
    [[type]] =
      repo().query!(
        "SELECT type::text FROM principals WHERE tenant_id=$1::text::uuid AND uid=$2",
        [Ankole.Repo.tenant_id!(), uid]
      ).rows

    {:ok, %{type: String.to_existing_atom(type)}}
  end

  defp legacy_group(name) do
    tenant = Ankole.Repo.tenant_id!()

    case repo().query!(
           "SELECT id::text FROM principal_groups WHERE tenant_id=$1::text::uuid AND name=$2",
           [tenant, name]
         ).rows do
      [[id]] ->
        {:ok, %{id: id}}

      [] ->
        condition =
          case name do
            "all_humans" ->
              ~s(principal.type == "human" && principal.membership == "member" && principal.status == "active")

            "all_agents" ->
              ~s(principal.type == "agent" && principal.status == "active")

            "pod_admin" ->
              nil
          end

        id = Ankole.Ecto.UUIDv7.autogenerate()

        repo().query!(
          """
          INSERT INTO principal_groups(id,tenant_id,name,display_name,kind,built_in,computed_condition,inserted_at,updated_at)
          VALUES($1::text::uuid,$2::text::uuid,$3,$3,$4::principal_group_kind,true,$5,now(),now())
          """,
          [id, tenant, name, if(condition, do: "computed", else: "static"), condition]
        )

        {:ok, %{id: id}}
    end
  end

  defp legacy_role(subject, resource, role) do
    target =
      case String.split(resource, ":") do
        ["drive", "**", id, "**"] -> id
        _ -> nil
      end

    actions =
      case role do
        "view" -> ~w(node_view)
        "manage" -> ~w(node_view node_contribute node_edit node_manage node_comment)
      end

    if target do
      {:ok, node} = legacy_fetch(target)
      {:ok, _} = legacy_update_anchor(node, :sharing, %{has_local_acl: true})
    end

    for action <- actions do
      repo().query!(
        """
        INSERT INTO permission_grants(id,tenant_id,principal_uid,group_id,resource_pattern,action,
          target_node_id,target_scope,inserted_at,updated_at)
        SELECT $1::text::uuid,$2::text::uuid,$3,$4::text::uuid,$5,$6,$7::text::uuid,
          CASE WHEN $7 IS NULL THEN NULL ELSE 'container' END,now(),now()
        WHERE NOT EXISTS (SELECT 1 FROM permission_grants WHERE tenant_id=$2::text::uuid
          AND principal_uid IS NOT DISTINCT FROM $3::text AND group_id IS NOT DISTINCT FROM $4::text::uuid
          AND resource_pattern=$5 AND action=$6)
        """,
        [
          Ankole.Ecto.UUIDv7.autogenerate(),
          Ankole.Repo.tenant_id!(),
          subject[:principal_uid],
          subject[:group_id],
          resource,
          action,
          target
        ]
      )
    end

    :ok
  end

  defp legacy_update_anchor(node, _action, changes) do
    # Every changed node becomes an anchor in this migration. Recompute all
    # descendant anchor pointers in one statement, preserving inherited grants.
    {:ok, current} = legacy_fetch(node.id)
    inherit = Map.get(changes, :inherit_permissions, current.inherit_permissions)

    parent_anchor =
      if node.parent_id do
        {:ok, parent} = legacy_fetch(node.parent_id)
        parent.acl_anchor_id
      end

    repo().query!(
      """
      UPDATE drive_nodes SET inherit_permissions=$3,has_local_acl=has_local_acl OR $4,
        deleted_at=COALESCE($5,deleted_at),acl_anchor_id=id,parent_anchor_id=$6::text::uuid
      WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid
      """,
      [
        Ankole.Repo.tenant_id!(),
        node.id,
        inherit,
        Map.get(changes, :has_local_acl, false),
        changes[:deleted_at],
        parent_anchor
      ]
    )

    repo().query!(
      """
      WITH RECURSIVE graph AS (
        SELECT tenant_id,id,acl_anchor_id FROM drive_nodes WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid
        UNION ALL SELECT n.tenant_id,n.id,CASE WHEN n.is_acl_anchor THEN n.id ELSE g.acl_anchor_id END
        FROM drive_nodes n JOIN graph g ON n.tenant_id=g.tenant_id AND n.parent_id=g.id
      ) UPDATE drive_nodes n SET acl_anchor_id=CASE WHEN n.is_acl_anchor THEN n.id ELSE g.acl_anchor_id END,
        parent_anchor_id=CASE WHEN n.is_acl_anchor THEN g.acl_anchor_id ELSE NULL END
      FROM graph g WHERE n.tenant_id=g.tenant_id AND n.parent_id=g.id
      """,
      [Ankole.Repo.tenant_id!(), node.id]
    )

    legacy_fetch(node.id)
  end

  defp page_view do
    """
    CREATE VIEW brain_page_nodes AS
    WITH RECURSIVE paths AS (
      SELECT tenant_id,id,''::text AS path FROM drive_nodes WHERE parent_id IS NULL
      UNION ALL SELECT n.tenant_id,n.id,CASE WHEN p.path='' THEN n.name ELSE p.path||'/'||n.name END
        FROM drive_nodes n JOIN paths p ON n.tenant_id=p.tenant_id AND n.parent_id=p.id
    )
    SELECT n.tenant_id,n.id,regexp_replace(paths.path,'^AnkoleBrain/','') AS slug,
      COALESCE(p.metadata->>'entity_type',n.kind) AS type,p.metadata->>'subtype' AS subtype,
      p.title,COALESCE(c.plain_text,'') AS body,COALESCE(c.content,'<page />') AS xml,
      p.metadata AS meta,p.upstream_state,p.revision,n.parent_id,n.acl_anchor_id,n.is_acl_anchor,n.kind,
      CASE WHEN p.metadata->>'effective_date' ~ '^\\d{4}-\\d{2}-\\d{2}$'
        AND pg_input_is_valid(p.metadata->>'effective_date','date')
        THEN (p.metadata->>'effective_date')::date END AS effective_date,
      p.revision::text AS content_hash,(p.upstream_state->>'source_id')::uuid AS managed_by_source_id,
      n.deleted_at,n.created_at,GREATEST(n.updated_at,p.updated_at) AS updated_at
    FROM drive_nodes n JOIN paths ON paths.tenant_id=n.tenant_id AND paths.id=n.id
      JOIN pages p ON p.tenant_id=n.tenant_id AND p.id=n.id
      LEFT JOIN page_contents c ON c.tenant_id=n.tenant_id AND c.page_id=n.id
    WHERE n.kind IN ('knowledge','doc','base','applet')
    """
  end
end
