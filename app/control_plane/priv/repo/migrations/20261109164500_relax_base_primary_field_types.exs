defmodule Ankole.Repo.Migrations.RelaxBasePrimaryFieldTypes do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE base_fields DROP CONSTRAINT base_fields_primary_text"
    execute(fn -> drop_legacy_field_indexes(repo()) end, fn -> :ok end)
  end

  def down do
    execute "ALTER TABLE base_fields ADD CONSTRAINT base_fields_primary_text CHECK (NOT is_primary OR type = 'text')"
  end

  def drop_legacy_field_indexes(repo) do
    rows =
      repo.query!(
        """
        SELECT t.base_db_id,
               replace(bt.tenant_id::text, '-', '') AS tenant_hex,
               replace(bf.id::text, '-', '') AS field_hex
        FROM base_fields bf
        JOIN base_tables bt ON bt.tenant_id = bf.tenant_id AND bt.id = bf.table_id
        JOIN tenants t ON t.id = bt.tenant_id
        WHERE bt.storage_mode = 'physical'
          AND bf.type <> 'auto_number'
        """,
        []
      ).rows

    rows
    |> Enum.group_by(&hd/1, fn [_shard_id, tenant_hex, field_hex] -> {tenant_hex, field_hex} end)
    |> Enum.each(fn {shard_id, indexes} ->
      drop_shard_indexes(shard_id, Enum.uniq(indexes))
    end)
  end

  defp drop_shard_indexes(_shard_id, []), do: :ok

  defp drop_shard_indexes(shard_id, indexes) do
    target_batches =
      indexes
      |> Enum.chunk_every(50)
      |> Enum.map(&format_index_targets/1)

    if Process.whereis(Ankole.Pod.BaseCluster.pool_name(shard_id)) do
      Ankole.Pod.BaseRepo.with_shard(shard_id, fn ->
        Enum.each(target_batches, fn targets ->
          Ankole.Pod.BaseRepo.query!("DROP INDEX IF EXISTS #{targets}", [])
        end)
      end)
    else
      shard =
        Enum.find(Ankole.Pod.BaseCluster.databases(), &(&1.id == shard_id)) ||
          raise "BASE_DB_URLS omits assigned shard: #{shard_id}"

      opts = Ecto.Repo.Supervisor.parse_url(shard.url) ++ [prepare: :unnamed]
      {:ok, conn} = Postgrex.start_link(opts)

      try do
        [[identity]] =
          Postgrex.query!(conn, "SELECT to_regclass('public._ankole_shard')::text", []).rows

        if identity, do: Ankole.Pod.BaseCluster.check_identity!(conn, shard.id)

        Enum.each(target_batches, fn targets ->
          Postgrex.query!(conn, "DROP INDEX IF EXISTS #{targets}", [])
        end)
      after
        GenServer.stop(conn)
      end
    end
  end

  defp format_index_targets(batch) do
    Enum.map_join(batch, ", ", fn {tenant_hex, field_hex} ->
      true = String.match?(tenant_hex, ~r/\A[0-9a-f]{32}\z/)
      true = String.match?(field_hex, ~r/\A[0-9a-f]{32}\z/)
      ~s("t_#{tenant_hex}"."ix_#{field_hex}")
    end)
  end
end
