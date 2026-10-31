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
    Page,
    PageChange,
    PageDailyActivity,
    PageComment,
    PageContent,
    PageSnapshot,
    Pages,
    PageUserState
  }

  require Ash.Query

  @batch_size 1000
  @impl Ankole.Job
  def run(%Oban.Job{args: %{"table_id" => id}}) do
    case Ankole.Pod.Bases.Delete.cleanup(id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def run(%Oban.Job{args: %{"page_id" => id}}) do
    case Repo.transact_top_level(fn -> start_in_tx(id) end) do
      {:ok, nil} -> :ok
      {:ok, _page} -> purge(id)
      {:error, {:retention_not_elapsed, seconds}} -> {:snooze, seconds}
      error -> error
    end
  end

  @doc false
  def start_in_tx(id) do
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
  end

  # 0 retains deleted pages; the job checks again each day in case the setting changes.
  defp mark_started(_page, 0), do: {:error, {:retention_not_elapsed, 86_400}}

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

  # Table cleanup commits shard deletion before metadata deletion. Page resources
  # are removed in bounded batches while the marked root remains present.
  defp purge(id) do
    ids = descendants(id)

    with :ok <- Ankole.Pod.Bases.Delete.purge_pages(ids),
         :ok <- delete_page_resources(ids),
         :ok <- remove_references(ids) do
      delete_pages(ids)
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

  defp delete_page_resources(ids) do
    replies = Ash.Query.filter(PageComment, page_id in ^ids and not is_nil(root_id))

    with :ok <- delete_resources(PageComment, :purge, replies) do
      Enum.reduce_while(
        [
          {PageUserState, :purge},
          {PageChange, :prune},
          {PageComment, :purge},
          {PageSnapshot, :purge},
          {PageDailyActivity, :purge},
          {PageContent, :purge}
        ],
        :ok,
        fn {resource, action}, :ok ->
          case delete_resources(resource, action, Ash.Query.filter(resource, page_id in ^ids)) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        end
      )
    end
  end

  defp delete_resources(resource, action, query) do
    case delete_batch(query, resource, action) do
      {:ok, 0} -> :ok
      {:ok, _count} -> delete_resources(resource, action, query)
      error -> error
    end
  end

  defp remove_references(ids) do
    Enum.reduce_while(ids, :ok, fn page_id, :ok ->
      case Repo.transact_top_level(fn -> remove_references_in_tx(page_id) end) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  def remove_references_in_tx(page_id) do
    Pages.lock_tree()

    with {:ok, _} <- Files.commit_in_tx(:pod, [], [Ankole.Pod.Files.prefix(page_id)]) do
      Access.grants(or: [[target_page_id: page_id], [source_page_id: page_id]])
      |> Access.remove_grants()

      {:ok, :cleaned}
    end
  end

  defp delete_pages(ids) do
    case Repo.transact_top_level(fn -> remove_pages_in_tx(ids) end) do
      {:ok, 0} -> :ok
      {:ok, _count} -> delete_pages(ids)
      error -> error
    end
  end

  @doc false
  def remove_pages_in_tx(ids) do
    Pages.lock_tree()
    delete_batch(Ash.Query.filter(Page, id in ^ids and not exists(children, true)), Page, :purge)
  end

  defp delete_batch(query, resource, action) do
    query
    |> Ash.Query.limit(@batch_size)
    |> Ash.Query.select(Ash.Resource.Info.primary_key(resource))
    |> Ankole.Ash.destroy_where(action)
    |> case do
      {:ok, records} -> {:ok, length(records)}
      error -> error
    end
  end
end
