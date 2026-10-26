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

  require Ash.Query

  alias Ankole.Files
  alias Ankole.Files.Schemas.Blob
  alias Ankole.Logging
  alias Ankole.ObjectStore
  alias Ankole.Repo

  @batch_size 100

  @impl Ankole.Job
  # Blob actions check references from every tenant before they collect content.
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
    with {:ok, records} <- Ankole.Ash.update_where(Blob, :mark_for_collection),
         do: {:ok, length(records)}
  end

  @doc false
  @spec remove_marked(non_neg_integer()) :: non_neg_integer()
  def remove_marked(removed) do
    case Repo.transact_top_level(fn -> remove_batch_in_tx() end) do
      {:ok, {0, _batch_removed}} -> removed
      {:ok, {_processed, batch_removed}} -> remove_marked(removed + batch_removed)
      {:error, reason} -> log_failure(reason, removed)
    end
  end

  @doc false
  # Returns how many marked rows the batch processed and how many it removed.
  def remove_batch_in_tx do
    digests =
      Blob
      |> Ash.Query.filter(deleting)
      |> Ash.Query.select([:sha256])
      |> Ash.Query.limit(@batch_size)
      |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.sha256)

    Enum.reduce_while(digests, {:ok, {0, 0}}, fn digest, {:ok, {processed, removed}} ->
      case remove_one(digest) do
        :removed -> {:cont, {:ok, {processed + 1, removed + 1}}}
        :kept -> {:cont, {:ok, {processed + 1, removed}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_one(digest) do
    query = Blob |> Ash.Query.filter(sha256 == ^digest)

    case Ankole.Ash.destroy_where(query, :collect) do
      {:ok, [_blob]} ->
        with :ok <- ObjectStore.delete(Files.object_key(digest)), do: :removed

      {:ok, []} ->
        with {:ok, _kept} <- Ankole.Ash.update_where(query, :keep_referenced), do: :kept

      error ->
        error
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
