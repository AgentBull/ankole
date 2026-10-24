defmodule Ankole.Pod.Database do
  @moduledoc """
  Owns logical Database tables, schema changes, and record commits.

  Each operation runs in a top-level transaction. Record rows belong to the
  Database subsystem (`Ankole.Pod.DbRecord`).
  """
  require Ash.Query
  alias Ankole.Repo

  alias Ankole.Pod.{
    Access,
    Config,
    DbField,
    DbTable,
    DbView,
    Pages,
    Query,
    Database.Records,
    Database.Write
  }

  def copy_table(uid, id, attrs, authority \\ nil),
    do: Ankole.Pod.Copy.table(uid, id, attrs, authority)

  def list_tables(uid, page_id) do
    with {:ok, %{type: :database}} <- Pages.authorize(uid, page_id, "page_view"),
         do:
           {:ok,
            %{
              tables:
                DbTable
                |> Ash.Query.filter(page_id == ^page_id)
                |> Ash.Query.sort(:position)
                |> Ankole.Ash.read!()
            }},
         else: (
           {:ok, _} -> {:error, :invalid_page_type}
           error -> error
         )
  end

  def create_table(uid, page_id, attrs, authority \\ nil),
    do: Access.write(authority, fn -> create_table_in_tx(uid, page_id, attrs) end)

  @doc false
  def create_table_in_tx(uid, page_id, attrs) do
    with {:ok, %{type: :database}} <- Pages.authorize(uid, page_id, "page_edit"),
         {:ok, table} <-
           Ankole.Ash.create(DbTable, :create_in_tx, %{
             page_id: page_id,
             name: Ankole.Attrs.get(attrs, :name, "Table"),
             position: Ankole.Attrs.get(attrs, :position, Ankole.Ecto.UUIDv7.autogenerate())
           }),
         {:ok, _} <-
           Ankole.Ash.create(DbField, :create_in_tx, %{
             table_id: table.id,
             name: "Name",
             type: :text,
             is_primary: true,
             position: "U"
           }),
         {:ok, _} <-
           Ankole.Ash.create(DbView, :create_in_tx, %{
             table_id: table.id,
             name: "Grid",
             type: :grid,
             position: "U"
           }) do
      {:ok, table}
    else
      {:ok, _} -> {:error, :invalid_page_type}
      error -> error
    end
  end

  def get_table(uid, id), do: Repo.transact_top_level(fn -> get_table_in_tx(uid, id) end)

  @doc false
  def get_table_in_tx(uid, id) do
    query_transaction(uid, id, fn table, limits ->
      definitions = fields(table.id)

      mode = if table.record_count <= limits["local_rows"], do: "local", else: "remote"

      {:ok, timezone} = Ankole.SystemConfig.timezone()

      {:ok,
       %{
         table: table,
         fields: definitions,
         views:
           DbView
           |> Ash.Query.filter(table_id == ^id)
           |> Ash.Query.sort(:position)
           |> Ankole.Ash.read!(),
         mode: mode,
         timezone: timezone,
         local_query: query_capabilities(),
         limits: limits
       }}
    end)
  end

  def query(uid, id, attrs),
    do: Repo.transact_top_level(fn -> query_in_tx(uid, id, attrs) end)

  @doc false
  def query_in_tx(uid, id, attrs) do
    query_transaction(uid, id, fn table, limits ->
      if Ankole.Attrs.get(attrs, :local, false) == true do
        local_records(table, fields(id), attrs, limits)
      else
        Query.records(table, fields(id), attrs,
          limit: min(limits["query_rows"], 200),
          max_limit: limits["query_rows"]
        )
      end
    end)
  end

  defp query_capabilities, do: __MODULE__.Capabilities.query_capabilities()

  defp local_records(table, fields, attrs, limits) do
    if table.record_count <= limits["local_rows"] do
      attrs =
        attrs
        |> Map.delete("page_token")
        |> Map.delete(:page_token)
        |> Map.delete("page_size")
        |> Map.put(:page_size, limits["local_rows"])

      with {:ok, result} <- Query.records(table, fields, attrs, max_limit: limits["local_rows"]) do
        if result.complete and byte_size(Torque.encode!(result.records)) <= limits["local_bytes"],
          do: {:ok, result},
          else: {:error, :local_table_changed}
      end
    else
      {:error, :local_table_changed}
    end
  end

  def aggregate(uid, id, attrs),
    do: Repo.transact_top_level(fn -> aggregate_in_tx(uid, id, attrs) end)

  @doc false
  def aggregate_in_tx(uid, id, attrs) do
    query_transaction(uid, id, fn table, limits ->
      case Query.aggregate(table, fields(id), attrs, max_groups: limits["group_count"]) do
        {:ok, %{groups: groups}} = result ->
          if length(groups) > limits["group_count"], do: {:error, :group_limit}, else: result

        result ->
          result
      end
    end)
  end

  defdelegate create_field(uid, id, attrs, authority \\ nil), to: Ankole.Pod.Database.Schema
  defdelegate update_field(uid, id, attrs, authority \\ nil), to: Ankole.Pod.Database.Schema
  defdelegate delete_field(uid, id, version, authority \\ nil), to: Ankole.Pod.Database.Schema
  defdelegate create_view(uid, id, attrs, authority \\ nil), to: Ankole.Pod.Database.Schema
  defdelegate update_view(uid, id, attrs, authority \\ nil), to: Ankole.Pod.Database.Schema
  defdelegate delete_view(uid, id, version, authority \\ nil), to: Ankole.Pod.Database.Schema

  def write_records(uid, id, attrs, authority \\ nil) do
    with {:ok, %{result: result}} <-
           Access.write(authority, fn -> write_records_in_tx(uid, id, attrs) end,
             after_commit: &committed_records/1
           ),
         do: {:ok, result}
  end

  @doc false
  def write_records_in_tx(uid, id, attrs) do
    with {:ok, write} <- Write.open(uid, id),
         {:ok, result} <- Records.batch(write, attrs),
         do: {:ok, %{table_id: write.table.id, result: result}}
  end

  @doc "Publishes committed record changes to the table rooms."
  def committed_records(%{table_id: id, result: result}), do: broadcast_result(id, result)

  @doc "Publishes committed schema changes to the table rooms."
  def committed_schema(%{changed: changed}), do: broadcast_schema(changed)

  def table_access(uid, id, action) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %DbTable{} = table <- Ankole.Ash.read_one!(Ash.Query.filter(DbTable, id == ^id)),
         {:ok, _} <- Pages.authorize(uid, table.page_id, action),
         do: {:ok, table},
         else: (
           nil -> {:error, :not_found}
           :error -> {:error, :not_found}
           error -> error
         )
  end

  def fields(id),
    do:
      DbField
      |> Ash.Query.filter(table_id == ^id)
      |> Ash.Query.sort(:position)
      |> Ankole.Ash.read!()

  # Sets the query limits for the rest of the calling action's transaction and
  # reads the table under a shared lock.
  defp query_transaction(uid, id, fun) do
    with {:ok, limits} <- Config.limits(),
         {:ok, table} <- table_access(uid, id, "page_view"),
         {:ok, timezone} <- Ankole.SystemConfig.timezone() do
      Repo.query!(
        "SELECT set_config('statement_timeout',$1,true),set_config('TimeZone',$2,true)",
        [to_string(limits["statement_timeout_ms"]), timezone]
      )

      case DbTable
           |> Ash.Query.filter(id == ^table.id)
           |> Ash.Query.lock("FOR SHARE")
           |> Ankole.Ash.read_one!() do
        nil -> {:error, :not_found}
        locked -> fun.(locked, limits)
      end
    end
  end

  defp broadcast_result(id, result) do
    notify(id, "changed", Map.take(result, [:data_version, :changed_ids, :deleted_ids]))

    Enum.each(Map.get(result, :related, []), fn item ->
      notify(item.id, "changed", Map.take(item, [:data_version, :changed_ids, :deleted_ids]))
    end)

    :ok
  end

  def broadcast_schema(changes) do
    Enum.each(changes, &notify(&1.id, "schema_changed", %{data_version: &1.data_version}))
  end

  defp notify(id, event, payload),
    do:
      Phoenix.PubSub.broadcast(
        Ankole.PubSub,
        "pod-room:table:" <> id,
        {:room_event, event, payload}
      )
end

defmodule Ankole.Pod.Database.Capabilities do
  @moduledoc false
  # The database catalog belongs to the site, not to a tenant.
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :site

  @doc "Tells which local query semantics match the database collation."
  def query_capabilities do
    [[collation, ctype, provider]] =
      Ankole.Repo.query!(
        "SELECT datcollate,datctype,datlocprovider::text FROM pg_database WHERE datname=current_database()",
        []
      ).rows

    %{
      text_contains_ascii: provider == "c" and ctype in ["C", "POSIX"],
      jsonb_compare: provider == "c" and collation in ["C", "POSIX", "C.UTF-8", "C.utf8"]
    }
  end
end
