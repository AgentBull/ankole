defmodule Ankole.Repo.Migrations.MigrateDocEmbedsToMentions do
  use Ecto.Migration

  @cdata_regex ~r/<!\[CDATA\[.*?\]\]>/su
  @embed_tag_regex ~r/<embed\b([^>]*?)(?:\/>|><\/embed>)/u
  @xml_attr_regex ~r/([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/u

  def up do
    tenant_ids =
      repo().query!("SELECT DISTINCT tenant_id::text FROM pages WHERE type = 'doc'", []).rows
      |> Enum.map(&hd/1)

    Enum.each(tenant_ids, &migrate_tenant/1)
  end

  def down, do: :ok

  defp migrate_tenant(tenant_id) do
    doc_ids =
      repo().query!(
        "SELECT id::text FROM pages WHERE tenant_id = $1::text::uuid AND type = 'doc'",
        [tenant_id]
      ).rows
      |> MapSet.new(&hd/1)

    migrate_contents(tenant_id, doc_ids)
    migrate_snapshots(tenant_id, doc_ids)
  end

  defp migrate_contents(tenant_id, doc_ids) do
    rows =
      repo().query!(
        """
        SELECT page.id::text, page.revision, content.content, content.updated_by
        FROM page_contents content
        JOIN pages page
          ON page.tenant_id = content.tenant_id AND page.id = content.page_id
        WHERE content.tenant_id = $1::text::uuid
          AND strpos(content.content, '<embed') > 0
        """,
        [tenant_id]
      ).rows

    Enum.each(rows, fn [page_id, revision, xml, author] ->
      with {:ok, %{xml: new_xml, plain_text: plain_text}} <-
             migrate_doc_embeds_xml(xml, doc_ids),
           {:ok, changes} when is_list(changes) and changes != [] <-
             Ankole.Kernel.page_diff(xml, new_xml) do
        new_revision = revision + 1

        repo().query!(
          """
          UPDATE page_contents
          SET content = $3, plain_text = $4
          WHERE tenant_id = $1::text::uuid AND page_id = $2::text::uuid
          """,
          [tenant_id, page_id, new_xml, plain_text]
        )

        repo().query!(
          """
          UPDATE pages
          SET revision = $3
          WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
          """,
          [tenant_id, page_id, new_revision]
        )

        repo().query!(
          """
          INSERT INTO page_changes
            (tenant_id, page_id, revision, kind, client_id, client_seq, changes, author, created_at)
          VALUES ($1::text::uuid, $2::text::uuid, $3, 'change', 'server:doc_embed_migration', $3, $4::text::jsonb, $5, now())
          """,
          [tenant_id, page_id, new_revision, Torque.encode!(changes), author]
        )
      else
        _ -> :ok
      end
    end)
  end

  defp migrate_snapshots(tenant_id, doc_ids) do
    rows =
      repo().query!(
        """
        SELECT id::text, content
        FROM page_snapshots
        WHERE tenant_id = $1::text::uuid
          AND strpos(content, '<embed') > 0
        """,
        [tenant_id]
      ).rows

    Enum.each(rows, fn [snapshot_id, xml] ->
      with {:ok, %{xml: new_xml}} <- migrate_doc_embeds_xml(xml, doc_ids),
           {:ok, info} <- Ankole.Kernel.page_comment_info(new_xml) do
        repo().query!(
          """
          UPDATE page_snapshots
          SET content = $3
          WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
          """,
          [tenant_id, snapshot_id, info.stripped_xml]
        )
      else
        _ -> :ok
      end
    end)
  end

  @doc """
  Rewrites document-targeting `<embed ref="<doc-id>" />` blocks into canonical
  `<p><mention page="<doc-id>" /></p>` paragraphs while leaving non-document
  embeds, external `href` embeds, CDATA code/math/diagram blocks, and inline
  comment anchors untouched.
  """
  def migrate_doc_embeds_xml(xml, %MapSet{} = doc_ids) when is_binary(xml) do
    if MapSet.size(doc_ids) == 0 or not String.contains?(xml, "<embed") do
      {:ok, :unchanged}
    else
      rewritten =
        @cdata_regex
        |> Regex.split(xml, include_captures: true)
        |> Enum.map(fn segment ->
          if String.starts_with?(segment, "<![CDATA[") do
            segment
          else
            rewrite_embed_tags(segment, doc_ids)
          end
        end)
        |> IO.iodata_to_binary()

      if rewritten == xml do
        {:ok, :unchanged}
      else
        case Ankole.Kernel.page_validate(rewritten) do
          {:ok, %{xml: ^xml}} -> {:ok, :unchanged}
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} = error -> error
        end
      end
    end
  end

  defp rewrite_embed_tags(segment, doc_ids) do
    Regex.replace(@embed_tag_regex, segment, fn full, raw_attrs ->
      attrs = parse_xml_attrs(raw_attrs)

      with false <- Map.has_key?(attrs, "href"),
           ref when is_binary(ref) <- Map.get(attrs, "ref"),
           {:ok, uuid} <- Ecto.UUID.cast(String.trim(ref)),
           true <- MapSet.member?(doc_ids, uuid) do
        ~s(<p><mention page="#{uuid}" /></p>)
      else
        _ -> full
      end
    end)
  end

  defp parse_xml_attrs(raw_attrs) do
    Regex.scan(@xml_attr_regex, raw_attrs)
    |> Map.new(fn
      [_, name, double_val] -> {name, double_val}
      [_, name, "", single_val] -> {name, single_val}
    end)
  end
end
