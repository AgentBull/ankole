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
  alias Ankole.Pod.{Access, Page, Pages}

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
      else: Repo.update(Page.changeset(page, %{purge_started_at: DateTime.utc_now(:microsecond)}))
  end

  defp purge(id) do
    ids = descendants(id)

    for table <- ~w(db_records db_views db_fields) do
      delete_batches(
        table,
        "table_id IN (SELECT id FROM db_tables WHERE tenant_id = $1::text::uuid AND page_id = ANY($2::text[]::uuid[]))",
        ids
      )
    end

    delete_batches("db_tables", "page_id = ANY($2::text[]::uuid[])", ids)

    for table <- ~w(page_user_states page_changes page_contents) do
      delete_batches(table, "page_id = ANY($2::text[]::uuid[])", ids)
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

  defp delete_batches(table, condition, ids) do
    {:ok, count} =
      Repo.transact(fn repo ->
        result =
          repo.query!(
            "DELETE FROM #{table} WHERE tenant_id = $1::text::uuid AND ctid IN (SELECT ctid FROM #{table} WHERE tenant_id = $1::text::uuid AND #{condition} LIMIT #{@batch_size})",
            [Repo.tenant_id!(), ids]
          )

        {:ok, result.num_rows}
      end)

    if count > 0, do: delete_batches(table, condition, ids), else: :ok
  end

  defp delete_pages(ids) do
    {:ok, count} =
      Repo.transact(fn repo ->
        Pages.lock_tree()

        result =
          repo.query!(
            """
            DELETE FROM pages WHERE tenant_id = $1::text::uuid AND id IN (
              SELECT p.id FROM pages p WHERE p.tenant_id = $1::text::uuid AND p.id = ANY($2::text[]::uuid[])
                AND NOT EXISTS (SELECT 1 FROM pages c WHERE c.tenant_id = $1::text::uuid AND c.parent_id = p.id)
              LIMIT #{@batch_size})
            """,
            [Repo.tenant_id!(), ids]
          )

        {:ok, result.num_rows}
      end)

    if count > 0, do: delete_pages(ids), else: :ok
  end
end
