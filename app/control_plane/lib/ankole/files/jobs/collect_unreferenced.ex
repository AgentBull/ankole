defmodule Ankole.Files.Jobs.CollectUnreferenced do
  @moduledoc """
  Removes old file contents without drive paths, Message attachments or uncompleted Delivery references.

  The job runs in two steps:

    1. One statement marks `deleting` on every unreferenced row whose
       `last_referenced_at` is older than one day. `store` and `commit` refresh
       `last_referenced_at` under the row lock, so a row that gets a new
       reference while this statement waits for its lock no longer matches.
    2. Batches of marked rows are locked with `SKIP LOCKED`. For each row the
       transaction deletes the row first, only if no reference exists, and
       then the object. A marked row that is still referenced loses its mark
       and keeps its object. If the object delete or the commit fails, the
       transaction rolls back and the row stays marked, so the next run
       repeats the delete; deleting a missing object succeeds.
  """

  use Ankole.Job,
    tenancy: :site,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: Oban.Job.states() -- [:completed, :cancelled, :discarded]]

  import Ecto.Query

  alias Ankole.Files
  alias Ankole.Files.Schemas.Blob
  alias Ankole.Logging
  alias Ankole.ObjectStore
  alias Ankole.Repo

  @batch_size 100
  @grace "1 day"

  # Both phases use the same all-tenant definition of a live reference.
  @unreferenced """
  AND NOT EXISTS (SELECT 1 FROM agent_files WHERE agent_files.sha256 = files.sha256)
  AND NOT EXISTS (
    SELECT 1 FROM deliveries AS intent
    WHERE intent.status IN ('pending', 'failed', 'unknown')
      AND intent.payload @> jsonb_build_object('attachments',
        jsonb_build_array(jsonb_build_object('blob_ref', encode(files.sha256, 'hex'))))
  )
  AND NOT EXISTS (
    SELECT 1 FROM conversation_messages AS message,
      unnest(message.attachments) AS attachment(value)
    WHERE attachment.value->>'blob_ref' = encode(files.sha256, 'hex')
  )
  """

  @impl Ankole.Job
  # Blob contents are site-owned. The two reviewed SQL statements check all
  # tenant references before deletion; this job needs no tenant query bypass.
  def run(job), do: sweep(job)

  defp sweep(%Oban.Job{}) do
    {:ok, marked} = mark_unreferenced()
    removed = remove_marked(0)

    if marked > 0 or removed > 0 do
      Logging.info("files.collect_unreferenced", "collected unreferenced file contents", %{
        marked: marked,
        removed: removed
      })
    end

    :ok
  end

  @doc false
  @spec mark_unreferenced() :: {:ok, non_neg_integer()}
  def mark_unreferenced do
    %{num_rows: count} =
      Repo.query!(
        """
        UPDATE files SET deleting = true
        WHERE NOT deleting
          AND last_referenced_at < now() - interval '#{@grace}'
          #{@unreferenced}
        """,
        []
      )

    {:ok, count}
  end

  @doc false
  @spec remove_marked(non_neg_integer()) :: non_neg_integer()
  def remove_marked(removed) do
    case Repo.transact(&remove_batch/1) do
      {:ok, {0, _batch_removed}} -> removed
      {:ok, {_processed, batch_removed}} -> remove_marked(removed + batch_removed)
      {:error, reason} -> log_failure(reason, removed)
    end
  end

  # Returns how many marked rows the batch processed and how many it removed.
  defp remove_batch(repo) do
    digests =
      from(blob in Blob,
        where: blob.deleting,
        select: blob.sha256,
        limit: @batch_size,
        lock: "FOR UPDATE SKIP LOCKED"
      )
      |> repo.all()

    Enum.reduce_while(digests, {:ok, {0, 0}}, fn digest, {:ok, {processed, removed}} ->
      case remove_one(repo, digest) do
        :removed -> {:cont, {:ok, {processed + 1, removed + 1}}}
        :kept -> {:cont, {:ok, {processed + 1, removed}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_one(repo, digest) do
    %{num_rows: deleted} =
      repo.query!(
        """
        DELETE FROM files
        WHERE sha256 = $1 AND deleting
          #{@unreferenced}
        """,
        [digest]
      )

    if deleted == 1 do
      with :ok <- ObjectStore.delete(Files.object_key(digest)), do: :removed
    else
      repo.update_all(where(Blob, [blob], blob.sha256 == ^digest), set: [deleting: false])
      :kept
    end
  end

  defp log_failure(reason, removed) do
    Logging.warning("files.collect_unreferenced_failed", "file content collection failed", %{
      reason: inspect(reason),
      removed: removed
    })

    removed
  end
end
