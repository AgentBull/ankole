defmodule Ankole.Repo.Migrations.AddBaseChartViewsAndMigrateDesignDirection do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE base_views DROP CONSTRAINT base_views_type_check")

    execute(
      "ALTER TABLE base_views ADD CONSTRAINT base_views_type_check CHECK (type IN ('grid', 'kanban', 'gallery', 'chart'))"
    )

    flush()
    migrate_design_contracts!(repo())
  end

  def down do
    execute("DELETE FROM base_views WHERE type = 'chart'")
    execute("ALTER TABLE base_views DROP CONSTRAINT base_views_type_check")

    execute(
      "ALTER TABLE base_views ADD CONSTRAINT base_views_type_check CHECK (type IN ('grid', 'kanban', 'gallery'))"
    )
  end

  def migrate_design_contracts!(repo) do
    raw_markdown = load_design_template!()
    {:ok, %{xml: xml, metadata: metadata}} = Ankole.Kernel.knowledge_parse(raw_markdown)
    {:ok, canonical_markdown} = Ankole.Kernel.knowledge_export(xml, metadata)
    new_hash = Ankole.Kernel.xxh3_128_hex(canonical_markdown)

    for [tenant_id] <- repo.query!("SELECT id::text FROM tenants ORDER BY id ASC").rows do
      Ankole.Repo.with_tenant(tenant_id, fn ->
        migrate_tenant_design_contracts!(
          repo,
          tenant_id,
          xml,
          canonical_markdown,
          metadata,
          new_hash
        )
      end)
    end
  end

  defp migrate_tenant_design_contracts!(
         repo,
         tenant_id,
         xml,
         canonical_markdown,
         metadata,
         new_hash
       ) do
    rows =
      repo.query!(
        """
        SELECT id::text, content_markdown, metadata, upstream_state, updated_by
        FROM agent_contracts
        WHERE tenant_id = $1::text::uuid
          AND agent_uid IS NULL
          AND slot = 'design'
        """,
        [tenant_id]
      ).rows

    Enum.each(rows, fn [id, content_markdown, current_metadata, upstream_state, updated_by] ->
      if uncustomized?(content_markdown, current_metadata, upstream_state, updated_by) and
           needs_migration?(
             content_markdown,
             current_metadata,
             upstream_state,
             canonical_markdown,
             metadata,
             new_hash
           ) do
        updated_upstream =
          if(is_map(upstream_state), do: upstream_state, else: %{})
          |> Map.merge(%{
            "upstream_base_hash" => new_hash,
            "upstream_latest_hash" => new_hash,
            "status" => "clean"
          })

        repo.query!(
          """
          UPDATE agent_contracts
          SET content_xml = $3,
              content_markdown = $4,
              metadata = $5::jsonb,
              revision = revision + 1,
              upstream_state = $6::jsonb,
              updated_at = NOW()
          WHERE tenant_id = $1::text::uuid
            AND id = $2::text::uuid
          """,
          [tenant_id, id, xml, canonical_markdown, metadata, updated_upstream]
        )
      end
    end)
  end

  defp uncustomized?(content_markdown, metadata, upstream_state, updated_by) do
    matches_upstream_base? =
      is_map(upstream_state) and is_binary(content_markdown) and
        is_binary(upstream_state["upstream_base_hash"]) and
        Ankole.Kernel.xxh3_128_hex(content_markdown) == upstream_state["upstream_base_hash"]

    legacy_unmodified_colors? =
      is_nil(updated_by) and is_map(metadata) and
        get_in(metadata, ["colors", "chart-up"]) == "#b31b5d" and
        get_in(metadata, ["colors", "chart-down"]) == "#24a148"

    matches_upstream_base? or legacy_unmodified_colors?
  end

  defp needs_migration?(
         content_markdown,
         current_metadata,
         upstream_state,
         canonical_markdown,
         metadata,
         new_hash
       ) do
    not (content_markdown == canonical_markdown and
           current_metadata == metadata and
           is_map(upstream_state) and
           upstream_state["upstream_base_hash"] == new_hash and
           upstream_state["upstream_latest_hash"] == new_hash and
           upstream_state["status"] == "clean")
  end

  defp load_design_template! do
    candidates = [
      Application.app_dir(:ankole, "../../library/templates/DESIGN.md"),
      Path.join([Ankole.AIAgent.Library.SourceReader.library_root(), "templates", "DESIGN.md"]),
      Path.expand("../../../../library/templates/DESIGN.md", __DIR__)
    ]

    case Enum.find(candidates, &File.regular?/1) do
      path when is_binary(path) -> File.read!(path)
      nil -> Ankole.AIAgent.Library.SourceReader.load_default_design_template()
    end
  end
end
