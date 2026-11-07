defmodule Ankole.Pod.FileExtraction do
  @moduledoc """
  Coordinates searchable text extraction and structure metadata caching for
  non-spreadsheet `type: :file` pages (`UTF-8` text/code/Markdown/JSON/CSV/TSV,
  `.docx`, `.pptx`, `.odt`, `.ods`, and text-layer `.pdf`).

  Small text files (`<= 256 KiB`) and shared immutable objects with an existing
  extracted cache commit synchronously inside the caller's transaction; larger
  text files and rich documents enqueue `Ankole.Pod.Jobs.SyncFileCache` so PDF
  and Office parsing runs on `DirtyCpu` outside page/tree locks.
  """

  require Ash.Query

  alias Ankole.Files, as: Drive
  alias Ankole.Kernel

  alias Ankole.Pod.{
    FileCache,
    Page,
    PageSearchDocument,
    Pages,
    SearchProjection,
    Spreadsheets
  }

  alias Ankole.Pod.FileExtraction.ScanCursor
  alias Ankole.Pod.Jobs.SyncFileCache
  alias Ankole.Repo

  @sync_text_max_bytes 262_144
  @max_text_extract_bytes 10 * 1024 * 1024
  @max_document_extract_bytes 32 * 1024 * 1024
  @default_missing_projection_budget 100
  @default_work_budget 50
  @default_scan_budget 200
  @duplicate_suffix ~r/ \(\d+\)$/

  @doc "Strips Drive's trailing duplicate suffix (` (n)`) when present before format classification."
  @spec clean_filename(String.t() | nil) :: String.t()
  def clean_filename(name) when is_binary(name), do: Regex.replace(@duplicate_suffix, name, "")
  def clean_filename(_), do: ""

  @doc "Maximum object byte size eligible for text extraction for `subtype`."
  @spec max_extract_bytes(:text | :document) :: pos_integer()
  def max_extract_bytes(:text), do: @max_text_extract_bytes
  def max_extract_bytes(:document), do: @max_document_extract_bytes

  @doc "Returns true when `page_id` already has both a current `FileCache` for `{object_id, format}` and a `PageSearchDocument` row."
  @spec current_cache?(String.t(), String.t(), String.t(), pos_integer()) :: boolean()
  def current_cache?(page_id, object_id, format, version) do
    cache_ok? =
      FileCache
      |> Ash.Query.filter(
        page_id == ^page_id and object_id == ^object_id and format == ^format and
          extractor_version >= ^version
      )
      |> Ankole.Ash.exists?()

    cache_ok? and
      PageSearchDocument
      |> Ash.Query.filter(page_id == ^page_id)
      |> Ankole.Ash.exists?()
  end

  @doc """
  Updates `FileCache` and `PageSearchDocument` (or enqueues `SyncFileCache`)
  when an immutable `object` is committed on a `type: :file` page inside a
  transaction. Spreadsheet files (`.xlsx` / `.xlsm`) are owned by
  `Ankole.Pod.Spreadsheets`.
  """
  @spec object_committed_in_tx(Page.t(), map()) :: :ok | {:error, term()}
  def object_committed_in_tx(%Page{type: :file} = page, %{id: object_id} = object)
      when is_binary(object_id) do
    Repo.require_transaction!({__MODULE__, :object_committed_in_tx})

    if Spreadsheets.spreadsheet?(page.name) do
      :ok
    else
      clean_name = clean_filename(page.name)
      version = Kernel.file_extractor_version()
      now = DateTime.utc_now(:microsecond)

      case Kernel.file_classify_format(clean_name, page.content_type) do
        :unsupported ->
          purge_and_clear_in_tx(page)

        {:ok, %{subtype: subtype, format: format}} ->
          max_bytes = max_extract_bytes(subtype)
          size = Map.get(object, :size) || 0

          cond do
            current_cache?(page.id, object_id, format, version) ->
              SearchProjection.upsert_in_tx(page)

            reuse_existing_object_cache_in_tx(page, subtype, format, object_id, version, now) ==
                :ok ->
              :ok

            size > max_bytes ->
              put_cache_and_projection_in_tx(
                page,
                %{
                  subtype: subtype,
                  format: format,
                  object_id: object_id,
                  extractor_version: version,
                  extract_status: :skipped,
                  extract_error: "file_too_large",
                  metadata: %{},
                  plain_text: ""
                },
                now
              )

            subtype == :text and size <= @sync_text_max_bytes ->
              extract_inline_or_enqueue_in_tx(
                page,
                clean_name,
                subtype,
                format,
                object_id,
                version,
                now
              )

            true ->
              with :ok <- purge_and_clear_in_tx(page),
                   do: enqueue_sync_in_tx(page.id, object_id)
          end
      end
    end
  end

  def object_committed_in_tx(_page, _object), do: :ok

  @doc """
  Reconciles extraction state when a `type: :file` page is renamed without
  changing its `object_id`.
  """
  @spec reconcile_renamed_in_tx(Page.t(), Page.t()) :: :ok | {:error, term()}
  def reconcile_renamed_in_tx(%Page{name: same}, %Page{name: same}), do: :ok

  def reconcile_renamed_in_tx(_previous, %Page{type: :file, object_id: object_id} = updated)
      when is_binary(object_id) do
    Repo.require_transaction!({__MODULE__, :reconcile_renamed_in_tx})
    rebuild_file_from_object_in_tx(updated)
  end

  def reconcile_renamed_in_tx(_previous, _updated), do: :ok

  @doc "Applies a `Kernel.file_extract_text/3` result to `FileCache` and `PageSearchDocument`."
  @spec persist_result_in_tx(
          Page.t(),
          :text | :document,
          String.t(),
          String.t(),
          pos_integer(),
          map(),
          DateTime.t()
        ) :: :ok | {:error, term()}
  def persist_result_in_tx(page, subtype, format, object_id, version, extracted, now) do
    case extracted do
      %{status: :ok, plain_text: plain_text, metadata: metadata} ->
        put_cache_and_projection_in_tx(
          page,
          %{
            subtype: subtype,
            format: format,
            object_id: object_id,
            extractor_version: version,
            extract_status: :ok,
            extract_error: nil,
            metadata: metadata || %{},
            plain_text: plain_text || ""
          },
          now
        )

      %{status: status, error: reason} when status in [:skipped, :failed] ->
        put_cache_and_projection_in_tx(
          page,
          %{
            subtype: subtype,
            format: format,
            object_id: object_id,
            extractor_version: version,
            extract_status: status,
            extract_error: to_string(reason),
            metadata: %{},
            plain_text: ""
          },
          now
        )
    end
  end

  @doc "Enqueues a deduplicated `SyncFileCache` job inside or outside a transaction."
  @spec enqueue_sync_in_tx(String.t(), String.t()) :: :ok | {:error, term()}
  def enqueue_sync_in_tx(page_id, object_id) do
    case Oban.insert(SyncFileCache.new(%{page_id: page_id, object_id: object_id})) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Bounded self-healing pass for one tenant:
  1. Rebuilds any `Page` missing its `PageSearchDocument` row (including
     re-extracting `:file` pages from their immutable Drive object).
  2. Scans at most `scan_budget` uncached `:file` rows starting from the
     tenant's saved scan cursor and enqueues up to `work_budget` missing or
     outdated file caches across supported formats.
  """
  @spec reconcile_tenant_batch(keyword()) :: :ok | {:error, term()}
  def reconcile_tenant_batch(opts \\ []) do
    missing_budget = Keyword.get(opts, :missing_budget, @default_missing_projection_budget)
    work_budget = Keyword.get(opts, :work_budget, @default_work_budget)
    scan_budget = Keyword.get(opts, :scan_budget, @default_scan_budget)

    with :ok <- backfill_missing_projections(missing_budget),
         do: reconcile_stale_files(work_budget, scan_budget)
  end

  defp rebuild_file_from_object_in_tx(%Page{type: :file, object_id: object_id} = page)
       when is_binary(object_id) do
    if Spreadsheets.spreadsheet?(page.name) do
      Spreadsheets.reconcile_file_in_tx(page)
    else
      case Drive.fetch_object(object_id) do
        {:ok, object} -> object_committed_in_tx(page, object)
        {:error, :not_found} -> purge_and_clear_in_tx(page)
      end
    end
  end

  defp rebuild_file_from_object_in_tx(page), do: SearchProjection.upsert_in_tx(page)

  defp extract_inline_or_enqueue_in_tx(page, clean_name, subtype, format, object_id, version, now) do
    case Drive.read_object(object_id) do
      {:ok, bytes} ->
        case Kernel.file_extract_text(bytes, clean_name, page.content_type) do
          {:ok, extracted} ->
            persist_result_in_tx(page, subtype, format, object_id, version, extracted, now)

          {:error, _reason} ->
            with :ok <- purge_and_clear_in_tx(page),
                 do: enqueue_sync_in_tx(page.id, object_id)
        end

      {:error, _reason} ->
        with :ok <- purge_and_clear_in_tx(page),
             do: enqueue_sync_in_tx(page.id, object_id)
    end
  end

  defp reuse_existing_object_cache_in_tx(page, subtype, format, object_id, version, now) do
    donor =
      FileCache
      |> Ash.Query.filter(
        object_id == ^object_id and format == ^format and extractor_version >= ^version and
          extract_status == :ok and page_id != ^page.id
      )
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    with %FileCache{} <- donor,
         %PageSearchDocument{body_text: body_text} <-
           PageSearchDocument
           |> Ash.Query.filter(page_id == ^donor.page_id)
           |> Ankole.Ash.read_one!() do
      put_cache_and_projection_in_tx(
        page,
        %{
          subtype: subtype,
          format: format,
          object_id: object_id,
          extractor_version: donor.extractor_version,
          extract_status: :ok,
          extract_error: nil,
          metadata: donor.metadata,
          plain_text: body_text
        },
        now
      )
    else
      _ -> :miss
    end
  end

  defp put_cache_and_projection_in_tx(page, attrs, now) do
    with {:ok, _cache} <-
           Ankole.Ash.create(FileCache, :put, %{
             page_id: page.id,
             subtype: attrs.subtype,
             format: attrs.format,
             object_id: attrs.object_id,
             extractor_version: attrs.extractor_version,
             extract_status: attrs.extract_status,
             extract_error: attrs.extract_error,
             metadata: attrs.metadata,
             updated_at: now
           }),
         do: SearchProjection.upsert_in_tx(page, body_text: attrs.plain_text)
  end

  defp purge_and_clear_in_tx(page) do
    with {:ok, _} <-
           FileCache
           |> Ash.Query.filter(page_id == ^page.id)
           |> Ankole.Ash.destroy_where(:purge),
         do: SearchProjection.upsert_in_tx(page, body_text: "")
  end

  defp backfill_missing_projections(limit) do
    missing =
      Page
      |> Ash.Query.filter(not exists(search_document, true) and is_nil(purge_started_at))
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(limit)
      |> Ankole.Ash.read!()

    Enum.reduce_while(missing, :ok, fn page, :ok ->
      case backfill_single_missing_page(page) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp backfill_single_missing_page(%Page{type: :file, object_id: object_id} = page)
       when is_binary(object_id) do
    unwrap_tx_result(
      Repo.transact_top_level(fn ->
        case Pages.lock(page.id) do
          {:ok, locked} -> rebuild_file_from_object_in_tx(locked)
          {:error, :not_found} -> :ok
        end
      end)
    )
  end

  defp backfill_single_missing_page(%Page{} = page) do
    unwrap_tx_result(
      Repo.transact_top_level(fn ->
        SearchProjection.upsert_in_tx(page)
      end)
    )
  end

  defp reconcile_stale_files(work_budget, scan_budget) do
    tenant_id = Repo.tenant_id!()
    version = Kernel.file_extractor_version()
    cursor = ScanCursor.get(tenant_id)
    {stale_pages, next_cursor} = scan_stale_file_batch(version, cursor, work_budget, scan_budget)

    result =
      Enum.reduce_while(stale_pages, :ok, fn page, :ok ->
        case reconcile_single_file(page) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    case result do
      :ok ->
        case next_cursor do
          nil -> ScanCursor.clear(tenant_id)
          value -> ScanCursor.put(tenant_id, value)
        end

      error ->
        error
    end
  end

  defp scan_stale_file_batch(version, cursor, work_budget, scan_budget) do
    query =
      Page
      |> Ash.Query.filter(
        type == :file and not is_nil(object_id) and is_nil(purge_started_at) and
          (not exists(search_document, true) or
             not exists(
               file_cache,
               object_id == parent(object_id) and
                 (subtype == :spreadsheet or extractor_version >= ^version)
             ))
      )
      |> then(fn q ->
        case cursor do
          nil ->
            q

          {after_ts, after_id} ->
            Ash.Query.filter(
              q,
              updated_at < ^after_ts or (updated_at == ^after_ts and id > ^after_id)
            )
        end
      end)
      |> Ash.Query.select([:id, :name, :title, :content_type, :object_id, :updated_at])
      |> Ash.Query.sort(updated_at: :desc, id: :asc)
      |> Ash.Query.limit(scan_budget)

    pages = Ankole.Ash.read!(query)
    caches_by_page = load_caches_by_page(Enum.map(pages, & &1.id))

    {rev_stale, stopped_at} =
      Enum.reduce_while(pages, {[], nil}, fn page, {acc, _last} ->
        next_acc =
          if stale_file_page?(page, Map.get(caches_by_page, page.id), version),
            do: [page | acc],
            else: acc

        if length(next_acc) >= work_budget do
          {:halt, {next_acc, {page.updated_at, page.id}}}
        else
          {:cont, {next_acc, nil}}
        end
      end)

    next_cursor =
      cond do
        stopped_at != nil ->
          stopped_at

        length(pages) >= scan_budget ->
          last = List.last(pages)
          {last.updated_at, last.id}

        true ->
          nil
      end

    {Enum.reverse(rev_stale), next_cursor}
  end

  defp load_caches_by_page([]), do: %{}

  defp load_caches_by_page(page_ids) do
    FileCache
    |> Ash.Query.filter(page_id in ^page_ids)
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.page_id, &1})
  end

  defp stale_file_page?(page, cache, version) do
    if Spreadsheets.spreadsheet?(page.name) do
      cache == nil or cache.object_id != page.object_id or cache.subtype != :spreadsheet
    else
      case Kernel.file_classify_format(clean_filename(page.name), page.content_type) do
        {:ok, %{format: format}} ->
          cache == nil or cache.object_id != page.object_id or cache.format != format or
            cache.extractor_version < version

        _ ->
          false
      end
    end
  end

  defp reconcile_single_file(page) do
    if Spreadsheets.spreadsheet?(page.name) do
      unwrap_tx_result(
        Repo.transact_top_level(fn ->
          case Pages.lock(page.id) do
            {:ok, locked} -> Spreadsheets.reconcile_file_in_tx(locked)
            {:error, :not_found} -> :ok
          end
        end)
      )
    else
      enqueue_sync_in_tx(page.id, page.object_id)
    end
  end

  defp unwrap_tx_result(:ok), do: :ok
  defp unwrap_tx_result({:ok, :ok}), do: :ok
  defp unwrap_tx_result({:ok, other}), do: other
  defp unwrap_tx_result(error), do: error
end
