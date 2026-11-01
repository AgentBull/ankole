defmodule Ankole.Pod.ContentOwner do
  @moduledoc "Cleans Pod content before Drive removes the referenced nodes."
  @behaviour Ankole.Files.ContentOwner
  require Ash.Query

  alias Ankole.Pod.{
    PageChange,
    PageDailyActivity,
    PageComment,
    PageContent,
    PageSnapshot,
    PageUserState
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
