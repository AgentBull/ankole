defmodule Ankole.Files.Jobs.PurgeNode do
  @moduledoc "Resumes subtree cleanup while retaining the marked root for retries."
  use Ankole.Job,
    tenancy: :tenant,
    queue: :default,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :retryable]
    ]

  require Ash.Query
  alias Ankole.Files.{Access, ContentOwner, Nodes}
  alias Ankole.Files.Schemas.Node
  alias Ankole.Repo

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"node_id" => id}}) do
    case Repo.transact_top_level(fn -> start_in_tx(id) end) do
      {:ok, nil} -> :ok
      {:ok, _} -> purge(id)
      {:error, {:retention_not_elapsed, seconds}} -> {:snooze, seconds}
      error -> error
    end
  end

  def start_in_tx(id) do
    Nodes.lock_tree()
    Nodes.lock_roots(Nodes.root_ids([id]))

    case Nodes.lock(id) do
      {:ok, %{deleted_at: nil}} ->
        {:ok, nil}

      {:ok, %{purge_started_at: started} = node} when not is_nil(started) ->
        {:ok, node}

      {:ok, node} ->
        with {:ok, days} <-
               Ankole.AppConfigure.get_tenant_by_key_in_tx("drive.trash_retention_days"),
             do: mark_started(node, days)

      {:error, :not_found} ->
        {:ok, nil}
    end
  end

  # 0 retains deleted nodes; the job checks again each day in case the setting changes.
  defp mark_started(_node, 0), do: {:error, {:retention_not_elapsed, 86_400}}

  defp mark_started(node, days) do
    remaining =
      DateTime.diff(
        DateTime.add(node.deleted_at, days * 86_400, :second),
        DateTime.utc_now(:microsecond),
        :microsecond
      )

    if remaining > 0,
      do: {:error, {:retention_not_elapsed, div(remaining + 999_999, 1_000_000)}},
      else:
        Nodes.update_in_tx(node, :begin_purge, %{
          purge_started_at: DateTime.utc_now(:microsecond)
        })
  end

  defp purge(id) do
    ids = Nodes.descendants(id)

    with :ok <- ContentOwner.purge_nodes(ids),
         :ok <- remove_references(ids),
         do: delete_nodes(ids)
  end

  defp remove_references(ids) do
    Repo.transact_top_level(fn ->
      Nodes.lock_tree()

      Access.grants(or: [[target_node_id: [in: ids]], [source_node_id: [in: ids]]])
      |> Access.remove_grants()

      :ok
    end)
  end

  defp delete_nodes(ids) do
    case Repo.transact_top_level(fn -> remove_nodes_in_tx(ids) end) do
      {:ok, 0} -> :ok
      {:ok, _} -> delete_nodes(ids)
      error -> error
    end
  end

  def remove_nodes_in_tx(ids) do
    Nodes.lock_tree()

    leaves =
      Repo.query!(
        """
        SELECT n.id::text FROM drive_nodes n
        WHERE n.tenant_id = $1::text::uuid AND n.id = ANY($2::text[]::uuid[])
          AND NOT EXISTS (SELECT 1 FROM drive_nodes c WHERE c.tenant_id = n.tenant_id AND c.parent_id = n.id)
        ORDER BY n.id LIMIT 1000
        """,
        [Repo.tenant_id!(), ids]
      ).rows
      |> Enum.map(&hd/1)

    Node
    |> Ash.Query.filter(id in ^leaves)
    |> Ankole.Ash.destroy_where(:remove)
    |> case do
      {:ok, nodes} -> {:ok, length(nodes)}
      error -> error
    end
  end
end
