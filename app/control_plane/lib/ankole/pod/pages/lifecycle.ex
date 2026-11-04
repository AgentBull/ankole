defmodule Ankole.Pod.Pages.Lifecycle do
  @moduledoc "Coordinates Page content and derived knowledge throughout the Page lifecycle."
  require Ash.Query

  alias Ankole.Pod.{
    FileCache,
    PageChange,
    PageDailyActivity,
    PageComment,
    PageContent,
    PageSnapshot,
    PageUserState,
    SpreadsheetOp
  }

  def move_node_in_tx(id, old_path), do: Ankole.Brain.Knowledge.page_moved_in_tx(id, old_path)

  def trash_node_in_tx(id), do: Ankole.Brain.Knowledge.page_deleted_in_tx(id)

  def restore_node_in_tx(id), do: Ankole.Brain.Knowledge.page_restored_in_tx(id)

  @batch_size 1000

  def release_applet_owners_for_tenant_deletion do
    Ankole.Pod.Page
    |> Ash.Query.filter(not is_nil(owner_uid))
    |> Ash.Query.limit(@batch_size)
    |> Ankole.Ash.update_where(:transfer_owner, %{owner_uid: nil}, select: [:id])
    |> case do
      {:ok, pages} -> {:ok, length(pages)}
      error -> error
    end
  end

  def purge_root_jobs_in_tx(root_ids) do
    ids = root_ids |> Enum.flat_map(&Ankole.Pod.Pages.Tree.descendants/1) |> Enum.uniq()
    Ankole.AutomationJobs.purge_pages_in_tx(ids)
  end

  def purge_nodes(ids) do
    with :ok <- Ankole.Pod.Bases.Delete.purge_pages(ids),
         :ok <- Ankole.AutomationJobs.purge_pages(ids),
         do: delete_page_resources(ids)
  end

  def purge_nodes_in_tx(ids) do
    :ok = Ankole.Repo.require_transaction()

    tables =
      Ankole.Pod.BaseTable
      |> Ash.Query.filter(page_id in ^ids)
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read!()

    Enum.reduce_while(tables, :ok, fn table, :ok ->
      case Ankole.Pod.Bases.Delete.drop_physical(table) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def rename_node_in_tx(_old, node, actor) do
    Ankole.Pod.Pages.rename_from_drive_in_tx(actor, node.id, node.name)
  end

  defp delete_page_resources(ids) do
    replies = Ash.Query.filter(PageComment, page_id in ^ids and not is_nil(root_id))

    with :ok <- delete_resources(PageComment, :purge, replies) do
      Enum.reduce_while(
        [
          {PageUserState, :purge},
          {PageChange, :prune},
          {SpreadsheetOp, :prune},
          {FileCache, :purge},
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
