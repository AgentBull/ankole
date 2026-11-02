defmodule Ankole.Pod.ContentOwner do
  @moduledoc """
  Keeps Pod content consistent with the Drive nodes it describes.

  Pod cleans its content before Drive removes the referenced nodes, renames
  pages after their nodes, and keeps a spreadsheet's operation log in step
  with the page's object (`Ankole.Pod.Spreadsheets`).
  """
  @behaviour Ankole.Files.ContentOwner
  require Ash.Query

  alias Ankole.Pod.{
    FileCache,
    PageChange,
    PageDailyActivity,
    PageComment,
    PageContent,
    PageSnapshot,
    PageUserState,
    Spreadsheets,
    SpreadsheetOp
  }

  @batch_size 1000

  @impl true
  def purge_nodes(ids) do
    with :ok <- Ankole.Pod.Bases.Delete.purge_pages(ids), do: delete_page_resources(ids)
  end

  @impl true
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

  @impl true
  def rename_node_in_tx(_old, %{kind: kind} = node, actor) when kind in [:doc, :base, :applet] do
    Ankole.Pod.Pages.rename_from_drive_in_tx(actor, node.id, node.name)
  end

  def rename_node_in_tx(_old, _node, _actor), do: :ok

  @impl true
  def object_committed_in_tx(previous, %{kind: :file} = node, actor),
    do: Spreadsheets.object_committed_in_tx(actor, previous, node)

  def object_committed_in_tx(_previous, _node, _actor), do: :ok

  @impl true
  def flush_node(id), do: Spreadsheets.flush_if_dirty(id)

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
