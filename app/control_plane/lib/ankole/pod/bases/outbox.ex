defmodule Ankole.Pod.Bases.Outbox do
  @moduledoc "Delivers compact Base batches after their storage transaction commits."
  require Ash.Query

  alias Ankole.Pod.{BaseRepo, Bases}
  alias Bases.{ChangeOutbox, Physical}

  def append(_write, %{emit_changes: false}, _rows), do: :ok
  def append(_write, _table, []), do: :ok

  def append(write, table, rows) do
    # A link edit can affect more records than the caller's batch. Compact repeated
    # touches of one row, then persist bounded delivery batches in this transaction.
    rows
    |> Enum.reduce(%{}, fn row, by_id ->
      Map.update(by_id, row.id, row, fn previous ->
        if row.op == "delete",
          do: row,
          else: %{previous | fields: Enum.uniq(previous.fields ++ row.fields)}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.chunk_every(200)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case append_batch(write, table, batch) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp append_batch(write, table, rows) do
    attrs = %{
      id: Ash.UUIDv7.generate(),
      page_id: table.page_id,
      table_id: table.id,
      data_version: table.data_version,
      actor_ref: to_string(Ankole.ActorRef.from_writer(write.uid, Ankole.Repo.tenant_id!(), [])),
      changes: Ankole.Pod.Serialization.json_value(rows)
    }

    case table.storage_mode do
      :physical -> Physical.append_changes(table, attrs)
      :inline -> with {:ok, _} <- Ankole.Ash.create(ChangeOutbox, :append, attrs), do: :ok
    end
  end

  def wake do
    %{tenant_id: Ankole.Repo.tenant_id!()}
    |> Ankole.Pod.Jobs.DeliverBaseChanges.new()
    |> Oban.insert()
  end

  def drain do
    {inline_count, inline_errors} =
      drain_batches(&pending_inline/2, fn row ->
        Ankole.Repo.transact_top_level(fn -> Ankole.Ash.destroy(row, :acknowledge) end)
      end)

    {physical_count, physical_errors} =
      BaseRepo.with_shard(BaseRepo.shard!(), fn ->
        drain_batches(&Physical.pending_changes/2, fn row ->
          Physical.acknowledge_changes(row.id)
        end)
      end)

    if inline_count == 100 or physical_count == 100, do: wake()
    errors = Map.merge(inline_errors, physical_errors)
    if map_size(errors) == 0, do: :ok, else: {:error, {:table_failures, errors}}
  end

  defp pending_inline(excluded, limit) do
    ChangeOutbox
    |> Ash.Query.filter(table_id not in ^excluded)
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read!()
  end

  defp drain_batches(read, acknowledge, count \\ 0, errors \\ %{}) do
    limit = 100 - count
    rows = read.(Map.keys(errors), limit)

    {delivered, failures} =
      Enum.reduce(rows, {count, errors}, fn row, {total, failed} ->
        if Map.has_key?(failed, row.table_id) do
          {total, failed}
        else
          case deliver(row, acknowledge) do
            :ok -> {total + 1, failed}
            {:error, reason} -> {total, Map.put(failed, row.table_id, reason)}
          end
        end
      end)

    # Look beyond a failed table's queued rows without reordering that table.
    if length(rows) == limit and delivered < 100,
      do: drain_batches(read, acknowledge, delivered, failures),
      else: {delivered, failures}
  end

  defp deliver(row, acknowledge) do
    event = %{
      id: row.id,
      type: "base.records.changed",
      data: Map.take(row, [:page_id, :table_id, :data_version, :actor_ref, :changes])
    }

    with {:ok, _} <- Ankole.Signals.emit("base://#{row.table_id}", event),
         result when result == :ok or elem(result, 0) == :ok <- acknowledge.(row),
         do: :ok
  end
end
