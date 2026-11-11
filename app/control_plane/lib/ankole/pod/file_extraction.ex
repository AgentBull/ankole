defmodule Ankole.Pod.FileExtraction do
  @moduledoc """
  Coordinates searchable text extraction and structure metadata caching for
  non-spreadsheet `type: :file` pages (`UTF-8` text/code/Markdown/JSON/CSV/TSV,
  `.docx`, `.pptx`, `.odt`, `.ods`, and `.pdf`).

  Small text files (`<= 256 KiB`) and shared immutable objects with an existing
  extracted cache commit synchronously inside the caller's transaction; larger
  text files and rich documents enqueue `Ankole.Pod.Jobs.SyncFileCache` so PDF
  and Office parsing runs on `DirtyCpu` outside page/tree locks.

  A PDF page without a text layer is a scan, and the Pod's `ocr` model can read
  it. The OCR provider charges for every page, so `extract_text/5` sends a page
  only when its caller says so: `Ankole.Pod.Jobs.SyncFileCache` does for a file
  that was just uploaded, and for any other file only while an administrator
  has `pod.ocr_existing_scans` on. What OCR reads stays in the cache's `ocr`
  column, so no later extraction sends the same page again.

  Every cache write or purge tells `Ankole.Brain.Knowledge` in the same
  transaction, so Brain's chunks and facts follow the text that search holds.
  """

  require Ash.Query
  require Logger

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ModelProfiles
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
  # OCR runs as the tenant's `system` Principal, and AIGateway reads at most
  # this many pages of one PDF in a request.
  @ocr_subject_uid "system"
  @ocr_pages_per_request 100
  # The kernel keeps this much text of one file, so OCR text beyond it would be
  # paid for and dropped.
  @max_text_bytes 512 * 1024
  # A scan whose OCR run failed waits half an hour times its failures in a row.
  # After five failures in a row it is tried once a day, so an outage or an
  # empty account costs little and the scan is read once the provider works.
  @ocr_retry_minutes 30
  @ocr_quick_retries 5
  @ocr_slow_retry_minutes 24 * 60

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

  A commit is an upload unless `read_scans?: false` says that the file was
  already there. Only the job of an upload may send the file's scanned pages to
  OCR without `pod.ocr_existing_scans`.
  """
  @spec object_committed_in_tx(Page.t(), map(), keyword()) :: :ok | {:error, term()}
  def object_committed_in_tx(page, object, opts \\ [])

  def object_committed_in_tx(%Page{type: :file} = page, %{id: object_id} = object, opts)
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

            keep_cache_of_same_bytes_in_tx(page, object, format, version) == :ok ->
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
              enqueue_extraction_in_tx(page, object_id, Keyword.get(opts, :read_scans?, true))
          end
      end
    end
  end

  def object_committed_in_tx(_page, _object, _opts), do: :ok

  # An upload replaces the page's cache. A rebuild keeps the row until the job
  # replaces it, because the row holds what OCR read from this object.
  defp enqueue_extraction_in_tx(page, object_id, upload?) do
    cleared =
      if upload?, do: purge_and_clear_in_tx(page), else: SearchProjection.upsert_in_tx(page)

    with :ok <- cleared, do: enqueue_sync_in_tx(page.id, object_id, upload?)
  end

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

  @doc """
  Extracts a file's text together with what OCR has read from its scanned
  pages. `ocr` is the `ocr` map of the file's cache, and the function returns
  the extraction and the map to store with it.

  With `read_scans?`, the Pod's `ocr` model first reads the scanned pages of a
  PDF that it has not read. Each page it reads joins the text under its own
  `[Page N]` line, and `ocr_pages` in the metadata lists the pages whose text
  came from OCR. A page that OCR has read is not sent again, whether it had
  text or not. When a request fails, the pages read before it stay and
  `"failures"` in the returned map goes up by one.
  """
  @spec extract_text(binary(), String.t(), String.t() | nil, map(), boolean()) ::
          {:ok, map(), map()} | {:error, term()}
  def extract_text(bytes, clean_name, content_type, ocr \\ %{}, read_scans? \\ false) do
    read = Map.get(ocr, "pages", %{})

    with {:ok, extracted} <- extract_with(bytes, clean_name, content_type, read) do
      case read_scans? and ocr_configured?() and unread_pages(extracted.metadata, read) do
        [_ | _] = unread ->
          {new, failed?} = read_scanned_pages(bytes, unread, extracted)
          ocr = ocr_state(Map.merge(read, new), ocr, failed?)

          if new == %{} do
            {:ok, extracted, ocr}
          else
            with {:ok, extracted} <-
                   extract_with(bytes, clean_name, content_type, ocr["pages"]),
                 do: {:ok, extracted, ocr}
          end

        _none ->
          {:ok, extracted, ocr}
      end
    end
  end

  @doc "The cache that describes `object_id` on `page_id`, or nil."
  @spec cache(String.t(), String.t()) :: FileCache.t() | nil
  def cache(page_id, object_id) do
    FileCache
    |> Ash.Query.filter(page_id == ^page_id and object_id == ^object_id)
    |> Ankole.Ash.read_one!()
  end

  @doc """
  The `ocr` map to extract `object_id` on `page_id` with: the page's own, plus
  the pages that OCR has read for the same object on any other page. A file
  that several pages share is paid for once.
  """
  @spec known_ocr(String.t(), String.t()) :: map()
  def known_ocr(page_id, object_id) do
    caches =
      FileCache
      |> Ash.Query.filter(object_id == ^object_id)
      |> Ash.Query.select([:page_id, :ocr])
      |> Ankole.Ash.read!()

    own = Enum.find_value(caches, %{}, &(&1.page_id == page_id && &1.ocr))

    pages =
      Enum.reduce(caches, %{}, fn cache, pages ->
        # A page with text on one copy beats a copy that found none.
        Map.merge(pages, Map.get(cache.ocr, "pages", %{}), fn _page, known, read ->
          if known == "", do: read, else: known
        end)
      end)

    if pages == %{}, do: own, else: Map.put(own, "pages", pages)
  end

  @doc """
  Whether `cache` needs an extraction run for `format` at `version`: it is
  missing or outdated, it is a scan cached without its page list, `ocr` (from
  `known_ocr/2`) holds pages the cache has not taken in, or `read_scans?`
  holds and OCR has pages left to read.
  """
  @spec pending?(FileCache.t() | nil, String.t(), pos_integer(), map(), boolean()) :: boolean()
  def pending?(nil, _format, _version, _ocr, _read_scans?), do: true

  def pending?(%FileCache{} = cache, format, version, ocr, read_scans?) do
    known = Map.get(ocr, "pages", %{})

    cache.format != format or cache.extractor_version < version or unlisted_scan?(cache) or
      map_size(known) > map_size(Map.get(cache.ocr, "pages", %{})) or
      unmerged_ocr?(cache.metadata, known) or search_text_missing?(cache) or
      (read_scans? and ocr_configured?() and unread_pages(cache.metadata, known) != [])
  end

  # A run whose extraction could not be stored leaves the pages it read on the
  # cache row while the metadata still lists them without text.
  defp unmerged_ocr?(%{"textless_pages" => pages}, known) when is_list(pages),
    do: Enum.any?(pages, &(Map.get(known, Integer.to_string(&1), "") != ""))

  defp unmerged_ocr?(_metadata, _known), do: false

  # An extraction that succeeded has text. A rebuild of a page whose search
  # document was missing writes an empty one and keeps the cache row.
  defp search_text_missing?(%FileCache{extract_status: :ok, page_id: page_id}) do
    not (PageSearchDocument
         |> Ash.Query.filter(page_id == ^page_id and body_text != "")
         |> Ankole.Ash.exists?())
  end

  defp search_text_missing?(_cache), do: false

  @doc "Whether two objects hold the same bytes, by the SHA-256 that both carry."
  @spec same_bytes?(String.t(), String.t()) :: boolean()
  def same_bytes?(object_id, other_object_id) do
    with {:ok, %{sha256: sha256}} when is_binary(sha256) <- Drive.fetch_object(object_id),
         {:ok, %{sha256: ^sha256}} <- Drive.fetch_object(other_object_id) do
      true
    else
      _different -> false
    end
  end

  @doc """
  Keeps what a run read from OCR when its extraction could not be stored: the
  pages go onto the cache row that `object_id` already has on `page_id`, and
  the run counts as a failure. Without that row there is nowhere to keep them.
  """
  @spec keep_ocr(String.t(), String.t(), map()) :: :ok
  def keep_ocr(page_id, object_id, ocr) do
    ocr = Map.put(ocr, "failures", Map.get(ocr, "failures", 0) + 1)

    kept =
      Repo.transact_top_level(fn ->
        case cache(page_id, object_id) do
          %FileCache{} = row ->
            Ankole.Ash.create(
              FileCache,
              :put,
              row
              |> Map.take(
                ~w(page_id subtype format object_id extractor_version extract_status extract_error metadata)a
              )
              |> Map.merge(%{ocr: ocr, updated_at: DateTime.utc_now(:microsecond)})
            )

          nil ->
            {:ok, nil}
        end
      end)

    with {:error, reason} <- kept,
         do: Logger.warning("Pod could not keep the pages OCR read: #{inspect(reason)}")

    :ok
  end

  @doc """
  Counts the scanned PDFs outside the trash whose pages OCR has not read, and
  those pages. Console shows the numbers before an administrator accepts the
  charges for reading them. `counting` says that the numbers are still
  growing: some PDF has no current cache or no page list yet, which is the
  state right after an upgrade.
  """
  @spec unread_scans() :: %{
          files: non_neg_integer(),
          pages: non_neg_integer(),
          counting: boolean()
        }
  def unread_scans do
    version = Kernel.file_extractor_version()

    pages =
      Page
      |> Ash.Query.filter(
        type == :file and not in_trash and is_nil(purge_started_at) and
          exists(
            file_cache,
            object_id == parent(object_id) and format == "pdf" and unread_scan_pages > 0
          )
      )
      |> Ash.Query.select([:id])
      |> Ash.Query.load(
        file_cache:
          FileCache |> Ash.Query.select([:page_id]) |> Ash.Query.load(:unread_scan_pages)
      )
      |> Ankole.Ash.read!()

    counting =
      Page
      |> Ash.Query.filter(
        type == :file and not is_nil(object_id) and not in_trash and
          is_nil(purge_started_at) and
          ((content_type == "application/pdf" and
              not exists(file_cache, object_id == parent(object_id))) or
             exists(
               file_cache,
               object_id == parent(object_id) and format == "pdf" and
                 (extractor_version < ^version or
                    (extract_status == :skipped and extract_error == "empty_text_layer" and
                       fragment("NOT jsonb_exists(?, 'textless_pages')", metadata)))
             ))
      )
      |> Ankole.Ash.exists?()

    %{
      files: length(pages),
      pages: Enum.sum_by(pages, & &1.file_cache.unread_scan_pages),
      counting: counting
    }
  end

  @doc """
  Counts the unread scans of every Pod that follows the Site value of
  `pod.ocr_existing_scans`. A Site-level consent starts OCR for exactly these
  Pods; a Pod with its own value keeps it.
  """
  @spec unread_scans_following_site() :: %{
          files: non_neg_integer(),
          pages: non_neg_integer(),
          counting: boolean()
        }
  def unread_scans_following_site do
    none = %{files: 0, pages: 0, counting: false}

    fn ->
      if Ankole.Pod.Config.follows_site_ocr_existing_scans?(), do: unread_scans(), else: none
    end
    |> Ankole.Tenants.map_active()
    |> Enum.reduce(none, fn
      {_tenant_id, %{files: files, pages: pages, counting: counting}}, total ->
        %{
          files: total.files + files,
          pages: total.pages + pages,
          counting: total.counting or counting
        }

      {_tenant_id, _error}, total ->
        total
    end)
  end

  @doc "Applies an `extract_text/5` result and its `ocr` map to `FileCache` and `PageSearchDocument`."
  @spec persist_result_in_tx(
          Page.t(),
          :text | :document,
          String.t(),
          String.t(),
          pos_integer(),
          map(),
          map(),
          DateTime.t()
        ) :: :ok | {:error, term()}
  def persist_result_in_tx(page, subtype, format, object_id, version, extracted, ocr, now) do
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
            ocr: ocr,
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
            # A scan without any text keeps the page list that OCR works from.
            metadata: Map.get(extracted, :metadata) || %{},
            ocr: ocr,
            plain_text: ""
          },
          now
        )
    end
  end

  @doc """
  Enqueues a deduplicated `SyncFileCache` job inside or outside a transaction.
  `read_scans?` marks the job of an upload, which may send the file's scanned
  pages to OCR.
  """
  @spec enqueue_sync_in_tx(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def enqueue_sync_in_tx(page_id, object_id, read_scans? \\ false) do
    args = %{page_id: page_id, object_id: object_id}
    args = if read_scans?, do: Map.put(args, :read_scans, true), else: args

    case Oban.insert(SyncFileCache.new(args)) do
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
  3. Enqueues up to `work_budget` scanned PDFs: the ones cached without their
     page list, which costs nothing, and, while the Pod has an `ocr` model and
     `pod.ocr_existing_scans` is on, the ones with pages OCR has not read.
  """
  @spec reconcile_tenant_batch(keyword()) :: :ok | {:error, term()}
  def reconcile_tenant_batch(opts \\ []) do
    missing_budget = Keyword.get(opts, :missing_budget, @default_missing_projection_budget)
    work_budget = Keyword.get(opts, :work_budget, @default_work_budget)
    scan_budget = Keyword.get(opts, :scan_budget, @default_scan_budget)

    with :ok <- backfill_missing_projections(missing_budget),
         :ok <- reconcile_stale_files(work_budget, scan_budget),
         do: reconcile_scans(work_budget)
  end

  defp extract_with(bytes, clean_name, content_type, read) when map_size(read) == 0,
    do: Kernel.file_extract_text(bytes, clean_name, content_type)

  defp extract_with(bytes, clean_name, content_type, read) do
    page_texts = for {page, text} <- read, do: {String.to_integer(page), text}
    Kernel.file_extract_text(bytes, clean_name, content_type, page_texts)
  end

  # The pages without a text layer that OCR has not read, in page order.
  defp unread_pages(%{"textless_pages" => pages}, read) when is_list(pages),
    do: Enum.reject(pages, &is_map_key(read, Integer.to_string(&1)))

  defp unread_pages(_metadata, _read), do: []

  # A scan that an earlier release cached before the kernel listed its pages.
  defp unlisted_scan?(cache) do
    cache.extract_status == :skipped and cache.extract_error == "empty_text_layer" and
      not is_map_key(cache.metadata, "textless_pages")
  end

  # Sends `unread` to OCR in batches and returns what the model read and
  # whether a request failed. The batches read before a failure stay, because
  # the Pod has paid for them. A batch is sent only while the text that comes
  # before its first page leaves room in the file's text.
  defp read_scanned_pages(bytes, unread, extracted) do
    document = %{"content_type" => "application/pdf", "base64" => Base.encode64(bytes)}

    unread
    |> Enum.chunk_every(@ocr_pages_per_request)
    |> Enum.reduce_while({%{}, false}, fn [first | _] = batch, {read, _failed?} ->
      if text_before(extracted, first) + text_bytes(read) < @max_text_bytes do
        case read_batch(document, batch) do
          {:ok, texts} -> {:cont, {Map.merge(read, texts), false}}
          :failed -> {:halt, {read, true}}
        end
      else
        {:halt, {read, false}}
      end
    end)
  end

  # The bytes of extracted text that come before `page`.
  defp text_before(extracted, page) do
    case Enum.find(Map.get(extracted.metadata, "pages", []), &(&1["page"] > page)) do
      %{"start_byte" => start} -> start
      nil -> byte_size(extracted.plain_text)
    end
  end

  defp text_bytes(texts), do: Enum.sum_by(texts, fn {_page, text} -> byte_size(text) end)

  defp read_batch(document, batch) do
    # The kernel numbers pages from 1, and AIGateway numbers them from 0.
    request = %{
      "model" => "ocr.default",
      "document" => document,
      "pages" => Enum.map(batch, &(&1 - 1))
    }

    case AIGateway.create_ocr(@ocr_subject_uid, request, caller: "pod_files") do
      {:ok, %{body: %{"pages" => read}}} ->
        texts =
          for %{"index" => index, "markdown" => markdown}
              when is_integer(index) and is_binary(markdown) <- read,
              into: %{},
              # PostgreSQL cannot store a NUL byte in the cache's JSON.
              do: {index + 1, String.replace(markdown, <<0>>, "")}

        # A page outside the request means the OCR model counts pages another
        # way, and its text would land on the wrong page. Asking again would
        # pay again for the same answer, so the pages count as read without text.
        texts =
          if Enum.all?(Map.keys(texts), &(&1 in batch)) do
            texts
          else
            Logger.warning("OCR returned pages outside the request, so Pod uses none of its text")
            %{}
          end

        # A page the model returned nothing for has no text, and is not sent again.
        {:ok, Map.new(batch, &{Integer.to_string(&1), Map.get(texts, &1, "")})}

      {:error, reason} ->
        Logger.warning("OCR could not read the scanned pages of a PDF: #{inspect(reason)}")
        :failed
    end
  end

  defp ocr_state(pages, previous, true),
    do: %{"pages" => pages, "failures" => Map.get(previous, "failures", 0) + 1}

  defp ocr_state(pages, _previous, false), do: %{"pages" => pages}

  # The `system` Principal reads its own `ocr` override before the Pod and
  # Site profiles, which is how AIGateway resolves the request.
  defp ocr_configured? do
    match?({:ok, _profile}, ModelProfiles.get_model_profile(@ocr_subject_uid, "ocr"))
  end

  defp rebuild_file_from_object_in_tx(%Page{type: :file, object_id: object_id} = page)
       when is_binary(object_id) do
    if Spreadsheets.spreadsheet?(page.name) do
      Spreadsheets.reconcile_file_in_tx(page)
    else
      case Drive.fetch_object(object_id) do
        {:ok, object} -> object_committed_in_tx(page, object, read_scans?: false)
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
            persist_result_in_tx(page, subtype, format, object_id, version, extracted, %{}, now)

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
          page_id != ^page.id and
          (extract_status == :ok or
             (extract_status == :skipped and extract_error == "empty_text_layer"))
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
          extract_status: donor.extract_status,
          extract_error: donor.extract_error,
          metadata: donor.metadata,
          # A copy keeps what OCR has read, and its unread pages wait like the original's.
          ocr: donor.ocr,
          plain_text: body_text
        },
        now
      )
    else
      _ -> :miss
    end
  end

  # An Agent's `drive put`, a sync client, and a connector commit a file again
  # even when its bytes did not change, and every commit names a new object.
  # The same bytes extract to the same text, so the page's cache moves to the
  # new object, and nothing is extracted or sent to OCR a second time.
  defp keep_cache_of_same_bytes_in_tx(page, object, format, version) do
    with sha256 when is_binary(sha256) <- Map.get(object, :sha256),
         %FileCache{} = cache <-
           FileCache
           |> Ash.Query.filter(
             page_id == ^page.id and format == ^format and extractor_version >= ^version
           )
           |> Ankole.Ash.read_one!(),
         {:ok, %{sha256: ^sha256}} <- Drive.fetch_object(cache.object_id),
         %PageSearchDocument{body_text: body_text} <-
           PageSearchDocument
           |> Ash.Query.filter(page_id == ^page.id)
           |> Ankole.Ash.read_one!() do
      put_cache_and_projection_in_tx(
        page,
        %{
          subtype: cache.subtype,
          format: cache.format,
          object_id: object.id,
          extractor_version: cache.extractor_version,
          extract_status: cache.extract_status,
          extract_error: cache.extract_error,
          metadata: cache.metadata,
          ocr: cache.ocr,
          plain_text: body_text
        },
        # The row keeps its time, which a scan whose OCR run failed waits on.
        cache.updated_at
      )
    else
      _changed -> :miss
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
             ocr: Map.get(attrs, :ocr, %{}),
             updated_at: now
           }),
         :ok <- SearchProjection.upsert_in_tx(page, body_text: attrs.plain_text),
         do: Ankole.Brain.Knowledge.file_cache_changed_in_tx(page)
  end

  defp purge_and_clear_in_tx(page) do
    with {:ok, _} <-
           FileCache
           |> Ash.Query.filter(page_id == ^page.id)
           |> Ankole.Ash.destroy_where(:purge),
         :ok <- SearchProjection.upsert_in_tx(page, body_text: ""),
         do: Ankole.Brain.Knowledge.file_cache_changed_in_tx(page)
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

  # A scan cached without its page list is extracted again so that Console can
  # count its pages, and so is one whose stored OCR pages have not joined its
  # text; neither costs anything. A scan with unread pages is sent to
  # OCR, which costs the Pod money, only while `pod.ocr_existing_scans` is on.
  # A scan in the trash waits, whether Pod trashed the file or a folder above
  # it, and one whose OCR run failed waits longer after each failure: half an
  # hour times its failures, then a day.
  defp reconcile_scans(work_budget) do
    read? = Ankole.Pod.Config.ocr_existing_scans?() and ocr_configured?()

    Page
    |> Ash.Query.filter(
      type == :file and not is_nil(object_id) and not in_trash and
        is_nil(purge_started_at) and
        exists(
          file_cache,
          object_id == parent(object_id) and format == "pdf" and
            ((extract_status == :skipped and extract_error == "empty_text_layer" and
                fragment("NOT jsonb_exists(?, 'textless_pages')", metadata)) or
               unmerged_ocr_pages > 0 or
               (^read? and unread_scan_pages > 0 and
                  fragment(
                    "? < clock_timestamp() - make_interval(mins => CASE WHEN COALESCE((?->>'failures')::int, 0) < ? THEN ? * COALESCE((?->>'failures')::int, 0) ELSE ? END)",
                    updated_at,
                    ocr,
                    ^@ocr_quick_retries,
                    ^@ocr_retry_minutes,
                    ocr,
                    ^@ocr_slow_retry_minutes
                  )))
        )
    )
    |> Ash.Query.select([:id, :object_id])
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.limit(work_budget)
    |> Ankole.Ash.read!()
    # Jobs run side by side, and two pages that hold one object would each send
    # its scans. One page reads them, and the others take the stored pages on a
    # later pass.
    |> Enum.uniq_by(& &1.object_id)
    |> Enum.reduce_while(:ok, fn page, :ok ->
      case enqueue_sync_in_tx(page.id, page.object_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp scan_stale_file_batch(version, cursor, work_budget, scan_budget) do
    query =
      Page
      |> Ash.Query.filter(
        type == :file and not is_nil(object_id) and is_nil(purge_started_at) and
          (not exists(search_document, true) or
             not exists(
               file_cache,
               object_id == parent(object_id) and extractor_version >= ^version
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
    # The scan compares these fields only, and `ocr` can hold a file's whole text.
    |> Ash.Query.select([:page_id, :object_id, :subtype, :format, :extractor_version])
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.page_id, &1})
  end

  defp stale_file_page?(page, cache, version) do
    if Spreadsheets.spreadsheet?(page.name) do
      cache == nil or cache.object_id != page.object_id or cache.subtype != :spreadsheet or
        cache.extractor_version < version
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
