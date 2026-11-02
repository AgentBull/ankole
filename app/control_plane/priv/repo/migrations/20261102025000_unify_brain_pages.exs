defmodule Ankole.Repo.Migrations.UnifyBrainPages do
  use Ecto.Migration
  alias Ankole.AIAgent.Library.Knowledge, as: Library
  alias Ankole.Files.{Access, Nodes}
  alias Ankole.Pod.{PageContent, PageSnapshot, Pages}
  require Ash.Query

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

    for [tenant_id] <- repo().query!("SELECT id::text FROM tenants").rows do
      Ankole.Repo.with_tenant(tenant_id, fn ->
        Ankole.Brain.Schemas.Page
        |> Ankole.Ash.read!()
        |> Enum.each(fn page ->
          {:ok, _} =
            Ankole.Brain.Chunks.reconcile_in_tx(page,
              chunking:
                Enum.find(Ankole.Brain.Config.definitions(), &(&1.key == "brain.chunking")).default_value
            )

          {:ok, _} = Ankole.Brain.Links.reconcile_object_links_in_tx(page.id)
        end)

        chunking =
          Enum.find(Ankole.Brain.Config.definitions(), &(&1.key == "brain.chunking")).default_value

        for [source_id] <-
              repo().query!(
                "SELECT DISTINCT source_node_id::text FROM brain_timelines WHERE tenant_id=$1::text::uuid AND subject_page_id IS NULL",
                [tenant_id]
              ).rows do
          {:ok, _} = Ankole.Brain.Chunks.reconcile_node_in_tx(source_id, chunking: chunking)
        end
      end)
    end
  end

  def down,
    do:
      raise(
        Ecto.MigrationError,
        "Knowledge unification preserves content in Pod; restore a backup to reverse it"
      )

  defp migrate_tenant(tenant_id) do
    {:ok, namespace} = Library.ensure_namespace_in_tx()

    for [id] <-
          repo().query!("SELECT id::text FROM conversations WHERE tenant_id=$1::text::uuid", [
            tenant_id
          ]).rows do
      {:ok, _root} = Nodes.ensure_conversation_root_in_tx(id)
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
          case Library.child(parent.id, name) do
            {:ok, %{kind: :file}} ->
              raise("legacy knowledge parent is a file")

            {:ok, node} ->
              node

            {:error, :not_found} ->
              {:ok, node} = Library.ensure_child_in_tx(parent.id, name, :folder)
              node
          end
        end)

      {:ok, page} = Library.ensure_child_in_tx(parent.id, name, :knowledge, id: object["id"])
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

          {:ok, _} =
            Ankole.Ash.create(PageSnapshot, :append, %{
              page_id: node.id,
              revision: revision,
              title: object["title"],
              metadata: business_metadata(object, version["meta"]),
              content: parsed.xml,
              author: version["author"] || author(),
              document_updated_at: datetime(version["snapshot_at"]),
              created_at: datetime(version["snapshot_at"]),
              reason: if(mixed?, do: :baseline, else: :checkpoint)
            })
        end)

        repo().query!(
          "UPDATE pages SET revision=$3 WHERE tenant_id=$1::text::uuid AND id=$2::text::uuid",
          [tenant_id, node.id, if(mixed?, do: 1, else: length(versions) + 1)]
        )
      end)

      if object["deleted_at"],
        do:
          Access.update_anchor_in_tx(page, :trash, %{deleted_at: datetime(object["deleted_at"])})

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
    {:ok, node} = Nodes.ensure_conversation_root_in_tx(conversation_id)
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
    {:ok, root} = Library.root()
    root.id
  end

  defp source_fallback("principal:" <> uid = scope, _) do
    case Ankole.Principals.get_principal(uid) do
      {:ok, %{type: :system}} ->
        source_container(scope)

      {:ok, _} ->
        {:ok, node} = Nodes.ensure_private_root_in_tx(uid)
        node.id
    end
  end

  defp source_fallback("group:" <> _ = scope, conversation) when is_binary(conversation) do
    {:ok, node} = Nodes.ensure_conversation_root_in_tx(conversation)
    restricted_page(node, scope).id
  end

  defp source_fallback(scope, _), do: source_container(scope)

  defp source_container(scope) do
    {:ok, root} = Library.root()
    {:ok, sources} = Library.ensure_child_in_tx(root.id, "sources", :folder)
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
        {:ok, node} = Nodes.fetch(id)
        node

      [] ->
        base = scope |> String.split(":", parts: 2) |> List.last()
        {:ok, path} = Nodes.path(parent)

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

            if legacy == [] and Library.child(parent.id, candidate) == {:error, :not_found},
              do: candidate
          end)

        {:ok, node} =
          Library.ensure_child_in_tx(parent.id, name, :knowledge, inherit_permissions: false)

        grant_scope(node, scope)
        now = DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        put_content(node, "", %{}, name, now, now)
        remember(tenant, key, scope, node.id)
        node
    end
  end

  defp grant_scope(node, "group:" <> name) do
    {:ok, group} = Ankole.AuthZ.get_principal_group(name)
    :ok = Access.put_role(%{group_id: group.id}, "drive:**:#{node.id}:**", "view")
  end

  defp grant_scope(node, "principal:" <> uid),
    do: Access.put_role(%{principal_uid: uid}, "drive:**:#{node.id}:**", "view")

  defp protect_assistant(node, "agents/" <> uid) do
    case repo().query!(
           "SELECT owner_principal_uid FROM agents WHERE tenant_id=$1::text::uuid AND uid=$2 AND type='personal_assistant'",
           [Ankole.Repo.tenant_id!(), uid]
         ).rows do
      [[owner]] ->
        {:ok, _} = Access.update_anchor_in_tx(node, :sharing, %{inherit_permissions: false})
        :ok = Access.put_role(%{principal_uid: uid}, "drive:**:#{node.id}:**", "view")
        :ok = Access.put_role(%{principal_uid: owner}, "drive:**:#{node.id}:**", "manage")

      [] ->
        :ok
    end
  end

  defp protect_assistant(_, _), do: :ok

  defp put_content(node, body, metadata, title, created, updated) do
    {:ok, parsed} = Ankole.Kernel.knowledge_parse(body)
    at = datetime(updated)

    attrs = %{
      page_id: node.id,
      content: parsed.xml,
      plain_text: parsed.plain_text,
      updated_by: author(),
      updated_at: at
    }

    case Ankole.Ash.read_one!(Ash.Query.filter(PageContent, page_id == ^node.id)) do
      nil -> {:ok, _} = Ankole.Ash.create(PageContent, :create_in_tx, attrs)
      content -> {:ok, _} = Ankole.Ash.update(content, :replace, Map.delete(attrs, :page_id))
    end

    {:ok, properties} = Pages.ensure_properties_in_tx(node.id)

    {:ok, _} =
      Ankole.Ash.update(properties, :save_knowledge, %{
        metadata: metadata,
        title: title,
        updated_at: at
      })

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
