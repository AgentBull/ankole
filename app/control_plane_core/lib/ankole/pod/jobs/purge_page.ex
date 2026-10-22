defmodule Ankole.Pod.Jobs.PurgePage do
  @moduledoc "Resumes a deleted subtree's bounded cleanup while its root remains present."
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :retryable]
    ]

  alias Ankole.{Files, Repo}

  alias Ankole.Pod.{
    Access,
    DbField,
    DbRecord,
    DbTable,
    DbView,
    Page,
    PageChange,
    PageContent,
    Pages,
    PageUserState
  }

  require Ash.Query

  @batch_size 1000
  @impl Ankole.Job
  def run(%Oban.Job{args: %{"page_id" => id}}) do
    case begin_purge(id) do
      {:ok, nil} -> :ok
      {:ok, _page} -> purge(id)
      {:error, {:retention_not_elapsed, seconds}} -> {:snooze, seconds}
      error -> error
    end
  end

  defp begin_purge(id) do
    Repo.transact(fn _repo ->
      Pages.lock_tree()

      case Pages.lock(id) do
        {:ok, %{deleted_at: nil}} ->
          {:ok, nil}

        {:ok, %{purge_started_at: started} = page} when not is_nil(started) ->
          {:ok, page}

        {:ok, page} ->
          with {:ok, days} <- Ankole.Pod.Config.trash_retention_days(),
               do: mark_started(page, days)

        {:error, :not_found} ->
          {:ok, nil}
      end
    end)
  end

  defp mark_started(page, days) do
    remaining_microseconds =
      DateTime.diff(
        DateTime.add(page.deleted_at, days * 86_400, :second),
        DateTime.utc_now(:microsecond),
        :microsecond
      )

    if remaining_microseconds > 0,
      do: {:error, {:retention_not_elapsed, div(remaining_microseconds + 999_999, 1_000_000)}},
      else: Ankole.Ash.update(page, :begin_purge, %{})
  end

  defp purge(id) do
    ids = descendants(id)

    for resource <- [DbRecord, DbView, DbField] do
      resource
      |> Ash.Query.filter(exists(table, page_id in ^ids))
      |> delete_resources(:remove)
    end

    DbTable |> Ash.Query.filter(page_id in ^ids) |> delete_resources(:remove)

    for {resource, action} <- [
          {PageUserState, :purge},
          {PageChange, :prune},
          {PageContent, :purge}
        ] do
      delete_resources(resource, action, ids)
    end

    Enum.reduce_while(ids, :ok, fn page_id, :ok ->
      case Repo.transact(fn repo ->
             Pages.lock_tree()

             with {:ok, _} <- Files.commit(repo, :pod, [], [Ankole.Pod.Files.prefix(page_id)]) do
               Access.page_grants(page_id) |> Access.remove_grants()
               {:ok, :cleaned}
             end
           end) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
    |> case do
      :ok ->
        delete_pages(ids)
        :ok

      error ->
        error
    end
  end

  defp descendants(id) do
    Repo.query!(
      """
      WITH RECURSIVE subtree AS (
        SELECT id FROM pages WHERE tenant_id = $1::text::uuid AND id = $2::text::uuid
        UNION ALL SELECT c.id FROM pages c JOIN subtree s ON c.parent_id = s.id WHERE c.tenant_id = $1::text::uuid
      ) SELECT id::text FROM subtree
      """,
      [Repo.tenant_id!(), id]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp delete_pages(ids) do
    count =
      committed_batch!(fn ->
        Pages.lock_tree()
        Page |> Ash.Query.filter(id in ^ids) |> delete_batch(:purge)
      end)

    if count > 0, do: delete_pages(ids), else: :ok
  end

  defp delete_resources(resource, action, ids),
    do: resource |> Ash.Query.filter(page_id in ^ids) |> delete_resources(action)

  defp delete_resources(query, action) do
    count = committed_batch!(fn -> delete_batch(query, action) end)
    if count > 0, do: delete_resources(query, action), else: :ok
  end

  defp committed_batch!(fun) do
    case Repo.transact(fn _repo -> {:ok, fun.()} end) do
      {:ok, count} -> count
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp delete_batch(query, action) do
    query =
      query
      |> Ash.Query.limit(@batch_size)
      |> Ash.Query.select(Ash.Resource.Info.primary_key(query.resource))

    case Ankole.Ash.bulk_destroy(query, action, %{},
           strategy: [:atomic],
           return_records?: true,
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success, records: records} -> length(records)
      %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
    end
  end
end
