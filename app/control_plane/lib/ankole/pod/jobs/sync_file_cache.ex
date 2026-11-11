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

  import Ecto.Query, only: [from: 2]

  alias Ankole.Files, as: Drive
  alias Ankole.Kernel
  alias Ankole.Pod.{FileExtraction, Page, Pages, Spreadsheets}
  alias Ankole.Repo

  # A job waits this many seconds before it looks again while another job has
  # the same bytes at the OCR provider.
  @reader_wait_seconds 10
  # The job that reads refreshes its mark this often. A mark that was not
  # refreshed for the stale time belongs to a job whose node has died, and it
  # holds no other job back.
  @reader_beat_seconds 20
  @reader_stale_seconds 60

  @impl Ankole.Job
  def run(
        %Oban.Job{
          args: %{"page_id" => page_id, "object_id" => object_id} = args,
          attempt: attempt
        } = job
      )
      when is_binary(page_id) and is_binary(object_id) do
    with {:ok, %Page{type: :file, purge_started_at: nil, object_id: ^object_id} = page} <-
           Pages.fetch(page_id),
         false <- Spreadsheets.spreadsheet?(page.name),
         clean_name = FileExtraction.clean_filename(page.name),
         {:ok, %{subtype: subtype, format: format}} <-
           Kernel.file_classify_format(clean_name, page.content_type),
         {:ok, object} <- Drive.fetch_object(object_id) do
      read_scans? = read_scans?(page, args, attempt)
      sync = fn -> sync(page, clean_name, object, {subtype, format}, read_scans?) end

      # Without an `ocr` model no job sends anything, so none has to wait.
      if format == "pdf" and FileExtraction.ocr_configured?(),
        do: sync_as(reader(job, object, read_scans?), job, sync),
        else: sync.()
    else
      :unsupported -> :ok
      {:ok, _superseded} -> :ok
      true -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def run(_job), do: :ok

  defp sync(page, clean_name, object, {subtype, format}, read_scans?) do
    version = Kernel.file_extractor_version()
    cache = FileExtraction.cache(page.id, object.id)
    # Read after `reader/3`, so it holds what an earlier reader stored.
    ocr = FileExtraction.known_ocr(page.id, object.id)

    # A cache that is current has nothing left to extract, and a run that
    # came second must not pay for the same pages again.
    if FileExtraction.pending?(cache, format, version, ocr, read_scans?) do
      extract(page, clean_name, object, {subtype, format, version}, ocr, read_scans?)
    else
      :ok
    end
  end

  # OCR charges for every page, so one job at a time sends the scans of the
  # same bytes, whichever pages and objects hold them. A job that may read
  # scans marks its Oban row with the bytes unless a running job already
  # carries that mark, and it is then the reader. A job that finds the mark on
  # another running job is busy: it waits, and when it runs again `known_ocr/2`
  # holds the pages that the reader stored. The advisory lock orders the jobs
  # that look at the same moment, and the transaction ends before any request
  # goes to OCR. The mark ends with the job's first attempt, the only one that
  # reads scans, or when the reader has stopped refreshing it.
  defp reader(%Oban.Job{id: id} = job, object, read_scans?) do
    bytes = "#{Repo.tenant_id!()}:#{Base.encode16(object.sha256, case: :lower)}"
    stale = System.os_time(:second) - @reader_stale_seconds

    {:ok, reader} =
      Repo.transact_top_level(fn ->
        Ankole.AdvisoryLock.lock!(Repo, "pod-ocr-reader:" <> bytes)

        reading? =
          Repo.exists?(
            from j in Oban.Job,
              where:
                j.state == "executing" and j.worker == ^inspect(__MODULE__) and j.attempt == 1 and
                  j.id != ^(id || 0) and fragment("?->>'reads' = ?", j.meta, ^bytes) and
                  fragment("(?->>'reads_at')::bigint > ?", j.meta, ^stale)
          )

        cond do
          reading? -> {:ok, :busy}
          not (read_scans? and is_integer(id)) -> {:ok, :free}
          marked?(job, bytes) -> {:ok, {:reader, bytes}}
          # Without the mark no other job would see this one, so it waits.
          true -> {:ok, :busy}
        end
      end)

    reader
  end

  defp marked?(%Oban.Job{meta: meta} = job, bytes) do
    mark = %{"reads" => bytes, "reads_at" => System.os_time(:second)}
    match?({:ok, _job}, Oban.update_job(job, %{meta: Map.merge(meta, mark)}))
  end

  defp sync_as(:busy, _job, _sync), do: {:snooze, @reader_wait_seconds}
  defp sync_as(:free, _job, sync), do: sync.()

  # One OCR request can take longer than the time after which a mark is stale,
  # so a process of its own refreshes the reader's mark until the job is done.
  defp sync_as({:reader, bytes}, job, sync) do
    reader = self()
    beat = spawn(fn -> beat(Process.monitor(reader), job, bytes) end)

    try do
      sync.()
    after
      send(beat, :done)
    end
  end

  defp beat(reader, job, bytes) do
    receive do
      :done -> :ok
      {:DOWN, ^reader, :process, _pid, _reason} -> :ok
    after
      :timer.seconds(@reader_beat_seconds) ->
        Repo.without_tenant(fn -> marked?(job, bytes) end)
        beat(reader, job, bytes)
    end
  end

  # OCR costs the Pod money for every page, so only the first attempt of a job
  # reads scans: a later attempt may already have paid for them. The job of an
  # upload reads the uploaded file, and any other job reads scans only while an
  # administrator has `pod.ocr_existing_scans` on. A file in the trash is not
  # read, and neither is a file in a trashed folder.
  defp read_scans?(page, args, attempt) do
    attempt <= 1 and
      (args["read_scans"] == true or Ankole.Pod.Config.ocr_existing_scans?()) and
      not Ankole.Ash.load!(page, :in_trash).in_trash
  end

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
        committed =
          commit_extraction(page.id, page.object_id, subtype, format, version, result, read)

        if read != ocr, do: keep_or_share(committed, page, read, read["pages"] != ocr["pages"])
        committed

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The Pod has paid for the pages this run read. After a failed commit they
  # stay on the cache row, and after a commit every other page that holds the
  # same bytes takes them.
  defp keep_or_share({:error, _reason}, page, read, _new_pages?),
    do: FileExtraction.keep_ocr(page.id, page.object_id, read)

  defp keep_or_share(:ok, page, _read, true),
    do: FileExtraction.enqueue_copies(page.id, page.object_id)

  defp keep_or_share(:ok, _page, _read, false), do: :ok

  @doc false
  def commit_extraction(page_id, object_id, subtype, format, version, result, ocr \\ %{}) do
    case Repo.transact_top_level(fn ->
           case Pages.lock(page_id) do
             {:ok, %Page{type: :file, purge_started_at: nil, object_id: ^object_id} = locked} ->
               commit_locked_cas(locked, object_id, subtype, format, version, result, ocr)

             # A commit of the same bytes moved the page to a new object while this run
             # was reading. The result describes those bytes, so it is stored for the
             # new object and the pages are not bought again.
             {:ok, %Page{type: :file, purge_started_at: nil, object_id: current} = locked}
             when is_binary(current) ->
               if FileExtraction.same_bytes?(object_id, current),
                 do: commit_locked_cas(locked, current, subtype, format, version, result, ocr),
                 else: :ok

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
