defmodule Ankole.Pod.Jobs.SyncFileCache do
  @moduledoc """
  Extracts searchable plain text and structural metadata (`pages`, `line_count`,
  `row_count`) for a non-spreadsheet file page on `DirtyCpu` outside page/tree
  locks, committing under an `object_id` compare-and-set check. The Pod's `ocr`
  model reads the scanned pages of a PDF in the same run.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    # A second run would send the same scanned pages to OCR again, so a page
    # and its object have one job at a time, the running one included.
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:page_id, :object_id],
      states: [:available, :scheduled, :retryable, :executing]
    ]

  alias Ankole.Files, as: Drive
  alias Ankole.Kernel
  alias Ankole.Pod.{FileExtraction, Page, Pages, Spreadsheets}
  alias Ankole.Repo

  @impl Ankole.Job
  def run(%Oban.Job{
        args: %{"page_id" => page_id, "object_id" => object_id} = args,
        attempt: attempt
      })
      when is_binary(page_id) and is_binary(object_id) do
    with {:ok, %Page{type: :file, purge_started_at: nil, object_id: ^object_id} = page} <-
           Pages.fetch(page_id),
         false <- Spreadsheets.spreadsheet?(page.name),
         clean_name = FileExtraction.clean_filename(page.name),
         {:ok, %{subtype: subtype, format: format}} <-
           Kernel.file_classify_format(clean_name, page.content_type),
         {:ok, object} <- Drive.fetch_object(object_id) do
      version = Kernel.file_extractor_version()
      cache = FileExtraction.cache(page_id, object_id)
      ocr = FileExtraction.known_ocr(page_id, object_id)
      read_scans? = read_scans?(page, args, attempt)

      # A cache that is current has nothing left to extract, and a run that
      # came second must not pay for the same pages again.
      if FileExtraction.pending?(cache, format, version, ocr, read_scans?) do
        extract(page, clean_name, object, {subtype, format, version}, ocr, read_scans?)
      else
        :ok
      end
    else
      :unsupported -> :ok
      {:ok, _superseded} -> :ok
      true -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_job), do: :ok

  # OCR costs the Pod money for every page, so only the first attempt of a job
  # reads scans: a later attempt may already have paid for them. The job of an
  # upload reads the uploaded file, and any other job reads scans only while an
  # administrator has `pod.ocr_existing_scans` on. A file in the trash is not
  # read.
  defp read_scans?(%Page{deleted_at: nil}, args, attempt) do
    attempt <= 1 and
      (args["read_scans"] == true or Ankole.Pod.Config.ocr_existing_scans?())
  end

  defp read_scans?(_page, _args, _attempt), do: false

  defp extract(page, clean_name, object, {subtype, format, version}, ocr, read_scans?) do
    extracted =
      if (object.size || 0) > FileExtraction.max_extract_bytes(subtype) do
        {:ok, %{status: :skipped, error: "file_too_large"}, %{}}
      else
        with {:ok, bytes} <- Drive.read_object(page.object_id) do
          FileExtraction.extract_text(bytes, clean_name, page.content_type, ocr, read_scans?)
        end
      end

    case extracted do
      {:ok, result, read} ->
        with {:error, reason} <-
               commit_extraction(page.id, page.object_id, subtype, format, version, result, read) do
          # The Pod has paid for the pages this run read, so they outlive the failed commit.
          if read != ocr, do: FileExtraction.keep_ocr(page.id, page.object_id, read)
          {:error, reason}
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def commit_extraction(page_id, object_id, subtype, format, version, result, ocr \\ %{}) do
    case Repo.transact_top_level(fn ->
           case Pages.lock(page_id) do
             {:ok, %Page{type: :file, purge_started_at: nil, object_id: ^object_id} = locked} ->
               commit_locked_cas(locked, object_id, subtype, format, version, result, ocr)

             {:ok, _superseded} ->
               :ok

             {:error, :not_found} ->
               :ok
           end
         end) do
      :ok -> :ok
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_locked_cas(locked, object_id, subtype, format, version, result, ocr) do
    if Spreadsheets.spreadsheet?(locked.name) do
      :ok
    else
      clean_name = FileExtraction.clean_filename(locked.name)

      case Kernel.file_classify_format(clean_name, locked.content_type) do
        {:ok, %{subtype: ^subtype, format: ^format}} ->
          FileExtraction.persist_result_in_tx(
            locked,
            subtype,
            format,
            object_id,
            version,
            result,
            ocr,
            DateTime.utc_now(:microsecond)
          )

        {:ok, %{format: new_format}} ->
          if FileExtraction.current_cache?(locked.id, object_id, new_format, version) do
            :ok
          else
            FileExtraction.enqueue_sync_in_tx(locked.id, object_id)
          end

        :unsupported ->
          :ok
      end
    end
  end
end
