defmodule Ankole.Brain.LibraryKnowledge do
  @moduledoc """
  Projects shipped knowledge files (okf) into the Brain.

  An okf file is Brain Markdown carried by the product: YAML frontmatter with
  `slug`, `type`, optional `subtype` and `aliases`, a `title`, and a Markdoc
  body. `app/library/knowledge/` can carry a built-in set, and an Agent Plugin
  can carry one set in its `knowledge/` directory. The file is the authority and
  the Object row is a rebuildable projection, so a product upgrade lands by
  re-sync instead of data migration.

  Ownership rules:

  - Each set owns one `brain_sources` row (kind `library`); managed Objects
    carry `managed_by_source_id`. The Object write paths refuse instance
    edits to managed pages; claims, links, timelines, tags, and aliases on a
    managed slug are instance periphery and survive every re-sync.
  - An instance-owned row always shadows the projection at its slug. The
    Console fork operation clears the marker, which turns the page into
    ordinary instance knowledge and removes it from the upgrade flow.
  - Shipped knowledge is `world` scope. A body with an `audience` tag is
    rejected, as is a slug whose type is not installed.
  - A set that disappears — plugin disabled, directory removed — and an
    archived library Source withdraw their managed pages by soft delete.
  - Purge spares managed rows, so a withdrawal keeps the slug periphery and
    a returning set restores its pages in place.

  Dreaming treats managed pages as ordinary Objects: link extraction
  materializes their wikilinks and mentions on its normal watermark, and no
  claim extraction runs over them.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.AgentPlugins
  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.SourceReader, as: LibrarySourceReader
  alias Ankole.Brain.Config
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Sources
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Repo

  @source_kind "library"
  @builtin_set_id "library"
  @lazy_skill_set_id "lazyload-agent-skills"
  @lazy_skill_type "agent-skills"
  @lazy_skill_prefix "lazyload-agent-skills/"
  # One okf page is prose, not a data dump; a larger file is a mistake.
  @max_file_bytes 512 * 1024

  @doc """
  Reconciles every shipped knowledge set into the Brain and withdraws the
  sets that are gone. Runs inside the Self-healing sweep; every step is
  idempotent and an unchanged set only re-reads files.
  """
  @spec sync(keyword()) :: {:ok, map()} | {:error, term()}
  def sync(opts \\ []) do
    if Config.enabled?() do
      inventory =
        case Keyword.fetch(opts, :sets) do
          {:ok, sets} -> {:ok, sets}
          :error -> discover_sets()
        end

      case inventory do
        {:ok, sets} ->
          reports = Enum.map(sets, &sync_set/1)
          withdrawn_sets = withdraw_missing_sets(Enum.map(sets, & &1.set_id))

          {:ok, %{sets: length(sets), reports: reports, withdrawn_sets: withdrawn_sets}}

        {:error, _reason} = error ->
          error
      end
    else
      {:ok, %{status: :brain_disabled}}
    end
  end

  # ── Discovery ──

  # The built-in set ships with the library; a plugin set participates while
  # its plugin is instance-enabled (the inherited global default). Knowledge
  # is instance-level world content, so the per-Agent overrides that gate
  # tools and skills do not gate it.
  defp discover_sets do
    builtin = %{
      kind: :knowledge,
      set_id: @builtin_set_id,
      name: "Library knowledge",
      dir: Path.join(LibrarySourceReader.library_root(), "knowledge")
    }

    knowledge_sets = Enum.filter([builtin | plugin_sets()], &File.dir?(&1.dir))

    case lazy_skill_set() do
      {:ok, set} -> {:ok, knowledge_sets ++ [set]}
      {:error, _reason} = error -> error
    end
  end

  defp lazy_skill_set do
    case Library.shipped_skill_sources() do
      {:ok, sources} ->
        {:ok,
         %{
           kind: :lazy_skills,
           set_id: @lazy_skill_set_id,
           name: "Shipped lazy Agent Skills",
           skills: Enum.filter(sources, &(&1.metadata["brain_recall_only"] == true))
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp plugin_sets do
    with {:ok, plugins} <- AgentPlugins.sources(),
         {:ok, capabilities} <- AgentPlugins.global_capabilities() do
      enabled =
        capabilities
        |> Enum.filter(& &1["effective_enabled"])
        |> MapSet.new(& &1["id"])

      for %{id: id, root: root} <- plugins, MapSet.member?(enabled, id) do
        %{
          kind: :knowledge,
          set_id: "agent-plugin:" <> id,
          name: id <> " knowledge",
          dir: Path.join(root, "knowledge")
        }
      end
    else
      {:error, reason} ->
        Logging.warning("brain.library_knowledge.plugin_scan_failed", %{reason: inspect(reason)})
        []
    end
  end

  # ── One set ──

  defp sync_set(set) do
    case ensure_source(set) do
      {:ok, %Source{archived_at: %DateTime{}} = source} ->
        archived_report(source)

      {:ok, source} ->
        project_set(set, source)

      {:error, reason} ->
        %{set: set.set_id, status: :error, reason: inspect(reason)}
    end
  end

  defp ensure_source(set) do
    case Sources.get_or_create(%{
           upstream_id: set.set_id,
           kind: @source_kind,
           name: set.name,
           default_audience_scope: "world"
         }) do
      {:ok, source} -> {:ok, source}
      {:error, _reason} -> {:error, :library_source_registration_failed}
    end
  end

  defp project_set(%{kind: :lazy_skills} = set, source) do
    pages = Enum.map(set.skills, &skill_page/1)
    project_pages(set, source, pages, [], skill_fingerprint(set.skills))
  end

  defp project_set(%{kind: :knowledge} = set, source) do
    files = knowledge_files(set.dir)
    {pages, rejected} = parse_pages(files)
    project_pages(set, source, pages, rejected, fingerprint(files))
  end

  defp project_pages(set, source, pages, rejected, fingerprint) do
    counts =
      Enum.reduce_while(
        pages,
        %{projected: 0, unchanged: 0, shadowed: 0, conflicted: 0, errored: 0},
        fn page, counts ->
          case project_page(source, page) do
            {:error, :source_archived} -> {:halt, :archived}
            outcome -> {:cont, Map.update!(counts, outcome, &(&1 + 1))}
          end
        end
      )

    finish_projection(set, source, pages, rejected, fingerprint, counts)
  end

  defp finish_projection(_set, source, _pages, _rejected, _fingerprint, :archived),
    do: archived_report(source)

  defp finish_projection(set, source, pages, rejected, fingerprint, counts) do
    result =
      Repo.transact(fn repo ->
        with {:ok, current} <- Sources.lock_active(repo, source) do
          withdrawn =
            Objects.withdraw_library_projection(current, Enum.map(pages, & &1.slug), repo: repo)

          with {:ok, _source} <- Sources.record_revision(repo, current, fingerprint) do
            {:ok, withdrawn}
          end
        end
      end)

    if rejected != [] do
      Logging.warning("brain.library_knowledge.pages_rejected", %{
        set: set.set_id,
        rejected: Enum.take(rejected, 10)
      })
    end

    case result do
      {:ok, withdrawn} ->
        Map.merge(counts, %{
          set: set.set_id,
          status: :ok,
          pages: length(pages),
          rejected: length(rejected),
          withdrawn: withdrawn
        })

      {:error, :source_archived} ->
        archived_report(source)

      {:error, reason} ->
        %{set: set.set_id, status: :error, reason: inspect(reason)}
    end
  end

  defp skill_page(source) do
    tags = source.metadata["tags"] || []

    body =
      ["Name: #{source.name}", "", source.description]
      |> Kernel.++(if tags == [], do: [], else: ["", "Tags: " <> Enum.join(tags, ", ")])
      |> Enum.join("\n")

    %{
      slug: @lazy_skill_prefix <> source.name,
      type: @lazy_skill_type,
      subtype: nil,
      title: source.name,
      body: body,
      aliases: Enum.uniq([source.name | tags])
    }
  end

  defp skill_fingerprint(sources) do
    sources
    |> Enum.map_join(<<0>>, fn source -> source.name <> <<1>> <> source.source_hash end)
    |> NativeKernel.xxh3_128_hex()
  end

  defp knowledge_files(dir) do
    dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, content} when byte_size(content) <= @max_file_bytes ->
          [{Path.relative_to(path, dir), content}]

        {:ok, _oversized} ->
          [{Path.relative_to(path, dir), :oversized}]

        {:error, _reason} ->
          []
      end
    end)
  end

  defp parse_pages(files) do
    {pages, rejected} =
      Enum.reduce(files, {[], []}, fn {path, content}, {pages, rejected} ->
        case parse_page(content) do
          {:ok, page} -> {[page | pages], rejected}
          {:error, reason} -> {pages, [%{file: path, reason: reason} | rejected]}
        end
      end)

    dedupe_slugs(Enum.reverse(pages), Enum.reverse(rejected))
  end

  # A slug declared twice inside the shipped sets would make the projection
  # flap between two bodies; the first file wins and the duplicate reports.
  defp dedupe_slugs(pages, rejected) do
    {pages, rejected, _seen} =
      Enum.reduce(pages, {[], rejected, MapSet.new()}, fn page, {kept, rejected, seen} ->
        if MapSet.member?(seen, page.slug) do
          {kept, rejected ++ [%{file: page.slug, reason: :duplicate_slug}], seen}
        else
          {[page | kept], rejected, MapSet.put(seen, page.slug)}
        end
      end)

    {Enum.reverse(pages), rejected}
  end

  defp parse_page(:oversized), do: {:error, :file_too_large}

  defp parse_page(content) when is_binary(content) do
    with {:ok, header, body} <- split_frontmatter(content),
         {:ok, meta} <- parse_frontmatter(header),
         {:ok, page} <- build_page(meta, body) do
      {:ok, page}
    end
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, ~r/\r?\n---[ \t]*\r?\n/, parts: 2) do
      [header, body] -> {:ok, header, String.trim_leading(body, "\n")}
      _unclosed -> {:error, :unterminated_frontmatter}
    end
  end

  defp split_frontmatter(_content), do: {:error, :missing_frontmatter}

  defp parse_frontmatter(header) do
    case YamlElixir.read_from_string(header) do
      {:ok, meta} when is_map(meta) -> {:ok, meta}
      _invalid -> {:error, :invalid_frontmatter}
    end
  end

  defp build_page(meta, body) do
    slug = string_field(meta, "slug")
    type = string_field(meta, "type")
    title = string_field(meta, "title")

    aliases =
      meta |> Map.get("aliases", []) |> List.wrap() |> Enum.filter(&is_binary/1)

    cond do
      slug == nil ->
        {:error, :missing_slug}

      type == nil ->
        {:error, :missing_type}

      title == nil ->
        {:error, :missing_title}

      String.starts_with?(slug, [@lazy_skill_prefix, "agents/"]) ->
        {:error, {:reserved_object_slug, slug}}

      type in [@lazy_skill_type, "agent"] ->
        {:error, {:reserved_object_type, type}}

      not installed_type?(type) ->
        {:error, {:unknown_object_type, type}}

      String.contains?(body, "{% audience") ->
        {:error, :audience_tag_in_shipped_page}

      true ->
        {:ok,
         %{
           slug: slug,
           type: type,
           subtype: string_field(meta, "subtype"),
           title: title,
           body: body,
           aliases: aliases
         }}
    end
  end

  defp string_field(meta, key) do
    case Map.get(meta, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _missing ->
        nil
    end
  end

  defp installed_type?(type), do: Repo.exists?(SchemaType |> where([t], t.name == ^type))

  # ── One page ──

  # One page failing must not take the sweep down with it: the page reports
  # as errored and the rest of the set still lands.
  defp project_page(source, page) do
    case Objects.upsert_library_projection(source, page) do
      {:ok, outcome} -> outcome
      {:error, :source_archived} = error -> error
      {:error, reason} -> page_failed(page, inspect(reason))
    end
  rescue
    error -> page_failed(page, Exception.message(error))
  end

  defp page_failed(page, error) do
    Logging.warning("brain.library_knowledge.page_failed", %{slug: page.slug, error: error})
    :errored
  end

  # ── Withdrawal ──

  defp archived_report(source) do
    %{
      set: source.upstream_id,
      status: :archived,
      withdrawn: 0
    }
  end

  defp withdraw_missing_sets(active_set_ids) do
    Source
    |> where([source], source.kind == @source_kind)
    |> where([source], is_nil(source.archived_at))
    |> where([source], source.upstream_id not in ^active_set_ids)
    |> Repo.all()
    |> Enum.map(fn source ->
      %{set: source.upstream_id, withdrawn: Objects.withdraw_library_projection(source, [])}
    end)
  end

  defp fingerprint(files) do
    files
    |> Enum.map_join(<<0>>, fn
      {path, content} when is_binary(content) -> path <> <<1>> <> content
      {path, :oversized} -> path <> <<1>> <> "oversized"
    end)
    |> NativeKernel.xxh3_128_hex()
  end
end
