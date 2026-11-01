defmodule Ankole.Pod.BaseRepo do
  @moduledoc "Tenant-scoped physical Base storage on a fixed shard pool."
  use Ecto.Repo, otp_app: :ankole, adapter: Ecto.Adapters.Postgres
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :tenant_schema

  alias Ankole.{LockOrder, Repo}
  alias Ankole.Pod.BaseCluster

  def tenant_schema!, do: "t_" <> hex(Repo.tenant_id!())
  def hex(id), do: id |> Ecto.UUID.cast!() |> String.replace("-", "")
  def table(id), do: "\"#{tenant_schema!()}\".\"tbl_#{hex(id)}\""
  def column(id), do: "\"f_#{hex(id)}\""
  def states, do: "\"#{tenant_schema!()}\"._table_states"

  def edge(name) do
    true = Regex.match?(~r/\Alnk_[0-9a-f]{32}\z/, name)
    "\"#{tenant_schema!()}\".\"#{name}\""
  end

  def shard! do
    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    tenant.base_db_id
  end

  def with_shard(id, fun) do
    previous = put_dynamic_repo(BaseCluster.pool_name(id))

    try do
      fun.()
    after
      put_dynamic_repo(previous)
    end
  end

  def run(shard, fun, opts \\ []) do
    :ok = Repo.require_transaction()
    deadline = Keyword.get(opts, :deadline, Ankole.Files.Access.deadline())
    timezone = Keyword.get(opts, :timezone, "UTC")

    with_shard(shard, fn ->
      LockOrder.with_base_transaction(fn ->
        transact(
          fn ->
            if opts[:read_only],
              do: query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY", [])

            remaining = remaining!(deadline)

            statement_timeout =
              min(remaining, Keyword.get(opts, :statement_timeout_ms, remaining))

            query!(
              "SELECT set_config('transaction_timeout',$1,true),set_config('statement_timeout',$2,true),set_config('lock_timeout',$3,true),set_config('TimeZone',$4,true)",
              [
                to_string(remaining),
                to_string(statement_timeout),
                if(opts[:ddl], do: "2000", else: "5000"),
                timezone
              ]
            )

            result = fun.()
            remaining!(deadline)

            unless opts[:read_only],
              do: Repo.query!("SELECT 1", [], timeout: remaining!(deadline))

            result
          end,
          timeout: remaining!(deadline)
        )
      end)
    end)
  end

  defp remaining!(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: raise("Base transaction deadline exceeded")
    remaining
  end

  def ensure_schema! do
    schema = tenant_schema!()
    query!("SELECT pg_advisory_xact_lock(hashtext($1))", [schema])
    query!("CREATE SCHEMA IF NOT EXISTS \"#{schema}\"", [])

    query!(
      """
      CREATE TABLE IF NOT EXISTS #{states()} (
        table_id uuid PRIMARY KEY,
        schema_version bigint NOT NULL DEFAULT 0 CHECK(schema_version >= 0),
        data_version bigint NOT NULL CHECK(data_version >= 0),
        record_count bigint NOT NULL CHECK(record_count >= 0),
        next_auto_number bigint NOT NULL CHECK(next_auto_number >= 1)
      )
      """,
      []
    )
  end

  def delete_tenant(shard) do
    with_shard(shard, fn ->
      schema = tenant_schema!()

      [[exists?, names]] =
        query!(
          "SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname=$1), ARRAY(SELECT tablename FROM pg_tables WHERE schemaname=$1 ORDER BY tablename)",
          [schema]
        ).rows

      for batch <- Enum.chunk_every(names, 100) do
        {:ok, :ok} =
          transact(fn ->
            query!("SET LOCAL lock_timeout = '15s'", [])

            for name <- batch do
              query!(
                ~s(DROP TABLE IF EXISTS "#{schema}"."#{String.replace(name, "\"", "\"\"")}" CASCADE),
                []
              )
            end

            {:ok, :ok}
          end)
      end

      if exists? do
        transact(fn ->
          query!("SET LOCAL lock_timeout = '15s'", [])
          query!("DROP SCHEMA IF EXISTS \"#{schema}\" CASCADE", [])
          {:ok, :ok}
        end)
      else
        {:ok, :ok}
      end
    end)
  end
end
