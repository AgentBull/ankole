defmodule Ankole.Pod.Jobs.SyncFileCache do
  @moduledoc """
  Extracts searchable plain text and structural metadata (`pages`, `line_count`,
  `row_count`) for a non-spreadsheet file page on `DirtyCpu` outside page/tree
  locks, committing under an `object_id` compare-and-set check.
  """

  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker, :args],
      states: [:available, :scheduled, :retryable]
    ]

  alias Ankole.Files, as: Drive
  alias Ankole.Kernel
  alias Ankole.Pod.{FileExtraction, Page, Pages, Spreadsheets}
  alias Ankole.Repo

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"page_id" => page_id, "object_id" => object_id}})
      when is_binary(page_id) and is_binary(object_id) do
    with {:ok, %Page{type: :file, purge_started_at: nil, object_id: ^object_id} = page} <-
           Pages.fetch(page_id),
         false <- Spreadsheets.spreadsheet?(page.name),
         clean_name = FileExtraction.clean_filename(page.name),
         {:ok, %{subtype: subtype, format: format}} <-
           Kernel.file_classify_format(clean_name, page.content_type),
         {:ok, object} <- Drive.fetch_object(object_id) do
      version = Kernel.file_extractor_version()
      max_bytes = FileExtraction.max_extract_bytes(subtype)

      extracted =
        if (object.size || 0) > max_bytes do
          {:ok, %{status: :skipped, error: "file_too_large"}}
        else
          with {:ok, bytes} <- Drive.read_object(object_id) do
            Kernel.file_extract_text(bytes, clean_name, page.content_type)
          end
        end

      case extracted do
        {:ok, result} ->
          commit_extraction(page_id, object_id, subtype, format, version, result)

        {:error, :not_found} ->
          :ok

        {:error, reason} ->
          {:error, reason}
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

  @doc false
  def commit_extraction(page_id, object_id, subtype, format, version, result) do
    case Repo.transact_top_level(fn ->
           case Pages.lock(page_id) do
             {:ok, %Page{type: :file, purge_started_at: nil, object_id: ^object_id} = locked} ->
               commit_locked_cas(locked, object_id, subtype, format, version, result)

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

  defp commit_locked_cas(locked, object_id, subtype, format, version, result) do
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
