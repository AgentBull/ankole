defmodule Ankole.Repo.Migrations.MigrateBookmarksToEmbeds do
  use Ecto.Migration

  @cdata_regex ~r/<!\[CDATA\[.*?\]\]>/su
  @bookmark_tag_regex ~r/<bookmark\b((?:[^>"']|"[^"]*"|'[^']*')*?)(?:\/>|>\s*<\/bookmark>)/su
  @xml_attr_regex ~r/([A-Za-z_][A-Za-z0-9_.:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/su
  @xml_entity_regex ~r/&(?:#(\d+)|#x([0-9A-Fa-f]+)|(lt|gt|quot|apos|amp));/u

  @stripped_search_codepoints [<<0>>, <<0x1E>>, <<0x1F>>]
  @long_dictionary_run ~r/(?<![\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\x{30FC}\p{sc=Thai}\p{sc=Lao}\p{sc=Khmer}\p{sc=Myanmar}])[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\x{30FC}\p{sc=Thai}\p{sc=Lao}\p{sc=Khmer}\p{sc=Myanmar}]{257,}/u
  @dictionary_run_chunk ~r/.{256}(?=.)/su

  @dropped_legacy_attrs MapSet.new([
                          "href",
                          "src",
                          "view",
                          "title",
                          "description",
                          "image",
                          "height",
                          "mime",
                          "size",
                          "kind"
                        ])

  def up do
    execute(fn -> migrate_repo(repo()) end, fn -> :ok end)
  end

  def down, do: :ok

  def migrate_repo(repo) do
    tenant_ids =
      repo.query!(
        """
        SELECT DISTINCT tenant_id::text FROM page_contents WHERE strpos(content, '<bookmark') > 0
        UNION
        SELECT DISTINCT tenant_id::text FROM page_snapshots WHERE strpos(content, '<bookmark') > 0
        """,
        []
      ).rows
      |> Enum.map(&hd/1)

    Enum.each(tenant_ids, &migrate_tenant(repo, &1))
  end

  defp migrate_tenant(repo, tenant_id) do
    migrate_contents(repo, tenant_id)
    migrate_snapshots(repo, tenant_id)
  end

  defp migrate_contents(repo, tenant_id) do
    rows =
      repo.query!(
        """
        SELECT page.id::text, page.type, page.metadata, page.revision, content.content, content.updated_by
        FROM page_contents content
        JOIN pages page
          ON page.tenant_id = content.tenant_id AND page.id = content.page_id
        WHERE content.tenant_id = $1::text::uuid
          AND strpos(content.content, '<bookmark') > 0
        """,
        [tenant_id]
      ).rows

    Enum.each(rows, fn [page_id, type, metadata, revision, xml, author] ->
      page_type = String.to_existing_atom(type)

      case migrate_bookmarks_xml(xml, page_type) do
        {:ok, :unchanged} ->
          :ok

        {:ok, %{xml: new_xml, plain_text: plain_text}} ->
          changes =
            case Ankole.Kernel.page_diff(xml, new_xml) do
              {:ok, diff} when is_list(diff) and diff != [] ->
                diff

              other ->
                raise "Failed to compute bookmark migration diff for page #{page_id}: #{inspect(other)}"
            end

          projection =
            case Ankole.Kernel.vfs_projection(page_type, new_xml, metadata || %{}) do
              {:ok, projected} ->
                projected

              other ->
                raise "Failed to project migrated page #{page_id} (#{type}): #{inspect(other)}"
            end

          new_revision = revision + 1

          repo.query!(
            """
            UPDATE page_contents
            SET content = $3, plain_text = $4
            WHERE tenant_id = $1::text::uuid AND page_id = $2::text::uuid
            """,
            [tenant_id, page_id, new_xml, plain_text]
          )

          repo.query!(
            """
            UPDATE pages
            SET revision = $3,
                vfs_content_empty = $4,
                vfs_md_size = $5,
                vfs_md_blake3 = $6
            WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
            """,
            [
              tenant_id,
              page_id,
              new_revision,
              projection.vfs_content_empty,
              projection.vfs_md_size,
              projection.vfs_md_blake3
            ]
          )

          repo.query!(
            """
            INSERT INTO page_changes
              (tenant_id, page_id, revision, kind, client_id, client_seq, changes, author, created_at)
            VALUES ($1::text::uuid, $2::text::uuid, $3, 'change', 'server:bookmark_embed_migration', $3, $4::text::jsonb, $5, now())
            """,
            [tenant_id, page_id, new_revision, Torque.encode!(changes), author]
          )

          repo.query!(
            """
            UPDATE page_search_documents
            SET body_text = $3, updated_at = now()
            WHERE tenant_id = $1::text::uuid AND page_id = $2::text::uuid
            """,
            [tenant_id, page_id, sanitize_search_text(plain_text)]
          )

        {:error, reason} ->
          raise "Failed to migrate bookmarks in page #{page_id}: #{inspect(reason)}"
      end
    end)
  end

  defp migrate_snapshots(repo, tenant_id) do
    rows =
      repo.query!(
        """
        SELECT id::text, content
        FROM page_snapshots
        WHERE tenant_id = $1::text::uuid
          AND strpos(content, '<bookmark') > 0
        """,
        [tenant_id]
      ).rows

    Enum.each(rows, fn [snapshot_id, xml] ->
      case migrate_bookmarks_xml(xml) do
        {:ok, :unchanged} ->
          :ok

        {:ok, %{xml: new_xml}} ->
          case Ankole.Kernel.page_comment_info(new_xml) do
            {:ok, info} ->
              repo.query!(
                """
                UPDATE page_snapshots
                SET content = $3
                WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
                """,
                [tenant_id, snapshot_id, info.stripped_xml]
              )

            other ->
              raise "Failed to strip comments in migrated snapshot #{snapshot_id}: #{inspect(other)}"
          end

        {:error, reason} ->
          raise "Failed to migrate bookmarks in snapshot #{snapshot_id}: #{inspect(reason)}"
      end
    end)
  end

  @doc """
  Rewrites `<bookmark ... />` blocks into unified `<embed href="..." />` blocks
  (or inline `<p><a href="...">...</a></p>` paragraphs when `view` is `"link"`
  or `"title"` or the page is `:knowledge`), leaving CDATA code/math/diagram
  blocks and inline comment anchors untouched.
  """
  def migrate_bookmarks_xml(xml, page_type \\ :doc) when is_binary(xml) do
    if not String.contains?(xml, "<bookmark") do
      {:ok, :unchanged}
    else
      rewritten =
        @cdata_regex
        |> Regex.split(xml, include_captures: true)
        |> Enum.map(fn segment ->
          if String.starts_with?(segment, "<![CDATA[") do
            segment
          else
            rewrite_bookmark_tags(segment, page_type)
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

  defp rewrite_bookmark_tags(segment, page_type) do
    Regex.replace(@bookmark_tag_regex, segment, fn _full, raw_attrs ->
      attrs = parse_xml_attrs(raw_attrs)
      href = Map.get(attrs, "href") || Map.get(attrs, "src") || ""
      view = Map.get(attrs, "view")

      cond do
        page_type == :knowledge and String.trim(href) != "" ->
          label = if(view == "link", do: href, else: non_empty(Map.get(attrs, "title")) || href)
          ~s(<p><a href="#{escape_xml_attr(href)}">#{escape_xml_text(label)}</a></p>)

        page_type == :knowledge ->
          "<p></p>"

        view == "link" and String.trim(href) != "" ->
          ~s(<p><a href="#{escape_xml_attr(href)}">#{escape_xml_text(href)}</a></p>)

        view == "title" and String.trim(href) != "" ->
          label = non_empty(Map.get(attrs, "title")) || href
          ~s(<p><a href="#{escape_xml_attr(href)}">#{escape_xml_text(label)}</a></p>)

        true ->
          build_embed_tag(attrs, href, view)
      end
    end)
  end

  defp build_embed_tag(attrs, href, view) do
    base_pairs =
      [{"href", href}]
      |> maybe_put_attr("view", if(view == "preview", do: nil, else: "card"))
      |> maybe_put_attr("title", non_empty(Map.get(attrs, "title")))
      |> maybe_put_attr("description", non_empty(Map.get(attrs, "description")))
      |> maybe_put_attr("image", non_empty(Map.get(attrs, "image")))
      |> maybe_put_attr("height", valid_embed_height(Map.get(attrs, "height")))

    extra_pairs =
      attrs
      |> Enum.reject(fn {key, _val} -> MapSet.member?(@dropped_legacy_attrs, key) end)
      |> Enum.sort_by(&elem(&1, 0))

    serialized =
      (base_pairs ++ extra_pairs)
      |> Enum.map(fn {key, val} -> ~s(#{key}="#{escape_xml_attr(val)}") end)
      |> Enum.join(" ")

    "<embed #{serialized} />"
  end

  defp maybe_put_attr(pairs, _key, nil), do: pairs
  defp maybe_put_attr(pairs, key, value), do: pairs ++ [{key, value}]

  defp non_empty(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp non_empty(_), do: nil

  defp valid_embed_height(value) when is_binary(value) do
    if not String.starts_with?(value, "0") do
      case Integer.parse(value) do
        {n, ""} when n >= 160 and n <= 1600 -> value
        _ -> nil
      end
    end
  end

  defp valid_embed_height(_), do: nil

  defp parse_xml_attrs(raw_attrs) do
    Regex.scan(@xml_attr_regex, raw_attrs)
    |> Map.new(fn
      [_, name, double_val] -> {name, unescape_xml(double_val)}
      [_, name, "", single_val] -> {name, unescape_xml(single_val)}
    end)
  end

  defp unescape_xml(text) do
    Regex.replace(@xml_entity_regex, text, fn
      full, dec, "", "" when dec != "" ->
        decode_codepoint(dec, 10, full)

      full, "", hex, "" when hex != "" ->
        decode_codepoint(hex, 16, full)

      _full, "", "", "lt" ->
        "<"

      _full, "", "", "gt" ->
        ">"

      _full, "", "", "quot" ->
        "\""

      _full, "", "", "apos" ->
        "'"

      _full, "", "", "amp" ->
        "&"
    end)
  end

  defp decode_codepoint(digits, base, fallback) do
    case Integer.parse(digits, base) do
      {cp, ""} when cp > 0 and cp <= 0x10FFFF and (cp < 0xD800 or cp > 0xDFFF) ->
        <<cp::utf8>>

      _ ->
        fallback
    end
  end

  defp escape_xml_text(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape_xml_attr(text) do
    text
    |> escape_xml_text()
    |> String.replace("\"", "&quot;")
  end

  defp sanitize_search_text(nil), do: ""

  defp sanitize_search_text(text) when is_binary(text) do
    normalized =
      case :unicode.characters_to_nfkc_binary(text) do
        bin when is_binary(bin) -> bin
        _ -> text
      end

    normalized
    |> String.replace(@stripped_search_codepoints, "")
    |> then(
      &Regex.replace(@long_dictionary_run, &1, fn run ->
        Regex.replace(@dictionary_run_chunk, run, "\\0 ")
      end)
    )
  end
end
