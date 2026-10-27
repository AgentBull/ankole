defmodule Ankole.Pod.Bases do
  @moduledoc """
  Owns logical Base tables, schema changes, and record commits.

  Each operation runs in a top-level transaction. Inline records use
  `Ankole.Pod.BaseRecord`; physical records and counters use the tenant shard.
  """
  require Ash.Query
  alias Ankole.Repo
  alias Ankole.Pod.Bases.{Physical, Promote}

  @inline_max_rows 2_000
  @inline_max_bytes 4_194_304
  @max_links_per_field 2_000
  def inline_max_rows, do: @inline_max_rows
  def inline_max_bytes, do: @inline_max_bytes
  def max_links_per_field, do: @max_links_per_field

  def inline?(table),
    do:
      table.storage_mode == :inline and table.record_count <= @inline_max_rows and
        table.record_bytes <= @inline_max_bytes

  defp local_candidate?(table),
    do:
      table.record_count <= @inline_max_rows and
        (table.storage_mode == :physical or table.record_bytes <= @inline_max_bytes)

  alias Ankole.Pod.{
    Access,
    BaseRepo,
    Config,
    BaseField,
    BaseTable,
    BaseView,
    Pages,
    Query,
    Bases.Records,
    Bases.Write
  }

  def copy_table(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority
    Ankole.Pod.Copy.table(actor, id, attrs, authority)
  end

  defdelegate rename_table(actor, id, name, authority \\ nil), to: Ankole.Pod.Bases.Schema

  def list_tables(%Ankole.AuthZ.Actor{} = actor, page_id) do
    Repo.transact_top_level(fn ->
      with {:ok, %{type: :base}} <- Pages.authorize(actor, page_id, "page_view") do
        tables =
          BaseTable
          |> Ash.Query.filter(page_id == ^page_id and is_nil(deleting_at))
          |> Ash.Query.sort(id: :asc)
          |> Ash.Query.lock("FOR KEY SHARE")
          |> Ankole.Ash.read!()

        result =
          if Enum.any?(tables, &(&1.storage_mode == :physical)) do
            BaseRepo.run(BaseRepo.shard!(), fn -> Physical.refresh(tables) end, read_only: true)
          else
            {:ok, tables}
          end

        with {:ok, tables} <- result, do: {:ok, %{tables: Enum.sort_by(tables, & &1.position)}}
      else
        {:ok, _} -> {:error, :invalid_page_type}
        error -> error
      end
    end)
  end

  def create_table(%Ankole.AuthZ.Actor{} = actor, page_id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority
    Access.write(authority, fn -> create_table_in_tx(actor, page_id, attrs) end)
  end

  @doc false
  def create_table_in_tx(%Ankole.AuthZ.Actor{} = actor, page_id, attrs) do
    with {:ok, %{type: :base} = page} <- Pages.authorize(actor, page_id, "page_edit"),
         do: init_table_in_tx(page, attrs),
         else: (
           {:ok, _} -> {:error, :invalid_page_type}
           error -> error
         )
  end

  @doc false
  def init_default_table_in_tx(page, _uid), do: init_table_in_tx(page, %{name: "Table 1"})

  defp init_table_in_tx(page, attrs) do
    with {:ok, table} <-
           Ankole.Ash.create(BaseTable, :create_in_tx, %{
             page_id: page.id,
             name: Ankole.Attrs.get(attrs, :name, "Table"),
             position: Ankole.Attrs.get(attrs, :position, Ankole.Ecto.UUIDv7.autogenerate())
           }),
         {:ok, _} <-
           Ankole.Ash.create(BaseField, :create_in_tx, %{
             table_id: table.id,
             name: "Name",
             type: :text,
             is_primary: true,
             position: "U"
           }),
         {:ok, _} <-
           Ankole.Ash.create(BaseView, :create_in_tx, %{
             table_id: table.id,
             name: "Grid",
             type: :grid,
             position: "U"
           }) do
      {:ok, table}
    end
  end

  def get_table(%Ankole.AuthZ.Actor{} = actor, id) do
    Repo.transact_top_level(fn -> get_table_in_tx(actor, id) end)
  end

  @doc false
  def get_table_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    query_transaction(actor, id, fn table, limits, definitions, context ->
      mode = if local_snapshot?(table, definitions), do: "local", else: "remote"

      timezone = context.timezone

      {:ok,
       %{
         table: table,
         fields: definitions,
         views: context.views,
         mode: mode,
         timezone: timezone,
         local_query: context.capabilities,
         limits: limits
       }}
    end)
  end

  def query(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    Repo.transact_top_level(fn -> query_in_tx(actor, id, attrs) end)
  end

  @doc false
  def query_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    query_transaction(actor, id, fn table, limits, definitions, _context ->
      if Ankole.Attrs.get(attrs, :local, false) == true do
        local_records(table, definitions, attrs, limits)
      else
        Query.records(table, definitions, attrs,
          limit: min(limits["query_rows"], 200),
          max_limit: limits["query_rows"]
        )
      end
    end)
  end

  defp query_capabilities, do: __MODULE__.Capabilities.query_capabilities()

  defp local_snapshot?(table, fields),
    do: local_candidate?(table) and Query.snapshot_fits?(table, fields, @inline_max_bytes)

  defp local_records(table, fields, attrs, _limits) do
    if local_snapshot?(table, fields) do
      attrs =
        attrs
        |> Map.delete("page_token")
        |> Map.delete(:page_token)
        |> Map.delete("page_size")
        |> Map.put(:page_size, @inline_max_rows)

      with {:ok, result} <- Query.records(table, fields, attrs, max_limit: @inline_max_rows) do
        if result.complete,
          do: {:ok, result},
          else: {:error, :local_table_changed}
      end
    else
      {:error, :local_table_changed}
    end
  end

  def aggregate(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    Repo.transact_top_level(fn -> aggregate_in_tx(actor, id, attrs) end)
  end

  @doc false
  def aggregate_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    query_transaction(actor, id, fn table, limits, definitions, _context ->
      case Query.aggregate(table, definitions, attrs, max_groups: limits["group_count"]) do
        {:ok, %{groups: groups}} = result ->
          if length(groups) > limits["group_count"], do: {:error, :group_limit}, else: result

        result ->
          result
      end
    end)
  end

  defdelegate delete_table(actor, id, authority \\ nil), to: Ankole.Pod.Bases.Schema

  defdelegate create_field(actor, id, attrs, authority \\ nil), to: Ankole.Pod.Bases.Schema
  defdelegate update_field(actor, id, attrs, authority \\ nil), to: Ankole.Pod.Bases.Schema
  defdelegate delete_field(actor, id, version, authority \\ nil), to: Ankole.Pod.Bases.Schema
  defdelegate create_view(actor, id, attrs, authority \\ nil), to: Ankole.Pod.Bases.Schema
  defdelegate update_view(actor, id, attrs, authority \\ nil), to: Ankole.Pod.Bases.Schema
  defdelegate delete_view(actor, id, version, authority \\ nil), to: Ankole.Pod.Bases.Schema

  def write_records(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority

    with {:ok, before} <- fetch_table(id),
         {:ok, %{result: result}} <-
           Access.write(authority, fn -> write_records_in_tx(actor, before, attrs) end,
             timeout: if(before.storage_mode == :physical, do: 15_000, else: 60_000),
             after_commit: &committed_records/1
           ),
         do: {:ok, result},
         else: (
           {:error, :base_storage_changed} -> write_records(actor, id, attrs, authority)
           error -> error
         )
  end

  @doc false
  def write_records_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    with {:ok, write} <- Write.open(actor, id),
         {:ok, attrs} <- Records.prepare(write, attrs),
         {:ok, result} <- write_batch(write, attrs),
         do: {:ok, %{table_id: write.table.id, result: result}}
  end

  defp write_batch(%{table: %{storage_mode: :physical}} = write, attrs) do
    BaseRepo.run(
      write.shard,
      fn ->
        with {:ok, write} <- Physical.lock_states(write), do: Records.batch(write, attrs)
      end,
      deadline: write.deadline,
      timezone: write.timezone
    )
  end

  defp write_batch(write, attrs) do
    with {:ok, result} <- Records.batch(write, attrs),
         {:ok, table} <- Promote.if_needed(write),
         do: {:ok, Map.put(result, :resync, table.storage_mode == :physical)}
  end

  @doc "Publishes committed record changes to the table rooms."
  def committed_records(%{table_id: id, result: result}), do: broadcast_result(id, result)

  @doc "Publishes committed schema changes to the table rooms."
  def committed_schema(%{changed: changed} = result) do
    broadcast_schema(changed)
    if result[:analyze], do: Physical.analyze(result.analyze.shard, result.analyze.ids)
    :ok
  end

  def table_access(%Ankole.AuthZ.Actor{} = actor, %BaseTable{} = table, intent)
      when intent in [:read, :write_records, :manage_schema, :delete_table] do
    action =
      case intent do
        :read -> "page_view"
        :write_records -> "page_write_records"
        :manage_schema -> "page_edit"
        :delete_table -> "page_manage"
      end

    with {:ok, _} <- Pages.authorize(actor, table.page_id, action), do: {:ok, table}
  end

  def table_access(%Ankole.AuthZ.Actor{} = actor, id, intent)
      when intent in [:read, :write_records, :manage_schema, :delete_table] do
    with {:ok, table} <- fetch_table(id), do: table_access(actor, table, intent)
  end

  def reconcile_versions(ids, reachable) do
    ids = for id <- Enum.uniq(ids), {:ok, id} <- [Ecto.UUID.cast(id)], do: id

    tables =
      BaseTable
      |> Ash.Query.filter(id in ^ids and is_nil(deleting_at))
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.lock("FOR KEY SHARE")
      |> Ankole.Ash.read!()

    page_ids = Enum.map(tables, & &1.page_id)
    {anchors, own} = Ankole.Pod.Access.visibility_ids(reachable)

    visible =
      Ankole.Pod.Page
      |> Ash.Query.filter(
        id in ^page_ids and is_nil(deleted_at) and (acl_anchor_id in ^anchors or id in ^own)
      )
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> MapSet.new(& &1.id)

    tables = Enum.filter(tables, &MapSet.member?(visible, &1.page_id))
    {physical, inline} = Enum.split_with(tables, &(&1.storage_mode == :physical))

    result =
      if physical == [] do
        {:ok, []}
      else
        BaseRepo.run(
          BaseRepo.shard!(),
          fn ->
            Physical.versions(physical)
          end,
          read_only: true
        )
      end

    with {:ok, versions} <- result,
         do: {:ok, Enum.map(inline, &Map.take(&1, [:id, :data_version])) ++ versions}
  end

  def fetch_table(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %BaseTable{} = table <-
           Ankole.Ash.read_one!(Ash.Query.filter(BaseTable, id == ^id and is_nil(deleting_at))),
         do: {:ok, table},
         else: (_ -> {:error, :not_found})
  end

  def fields(id),
    do:
      BaseField
      |> Ash.Query.filter(table_id == ^id)
      |> Ash.Query.sort(:position)
      |> Ankole.Ash.read!()

  # Sets the query limits for the rest of the calling action's transaction and
  # reads the table under a shared lock.
  defp query_transaction(%Ankole.AuthZ.Actor{} = actor, id, fun) do
    with {:ok, candidate} <- fetch_table(id),
         {:ok, id} <- Ecto.UUID.cast(id),
         %BaseTable{} = locked <-
           BaseTable
           |> Ash.Query.filter(id == ^id and is_nil(deleting_at))
           |> Ash.Query.lock(
             if(candidate.storage_mode == :inline, do: "FOR SHARE", else: "FOR KEY SHARE")
           )
           |> Ankole.Ash.read_one!(),
         {:ok, table} <- table_access(actor, locked, :read),
         {:ok, limits} <- Config.limits(),
         {:ok, timezone} <- Ankole.SystemConfig.timezone() do
      Repo.query!(
        "SELECT set_config('statement_timeout',$1,true),set_config('TimeZone',$2,true)",
        [to_string(limits["statement_timeout_ms"]), timezone]
      )

      definitions = fields(table.id)

      views =
        BaseView
        |> Ash.Query.filter(table_id == ^id)
        |> Ash.Query.sort(:position)
        |> Ankole.Ash.read!()

      capabilities = query_capabilities()
      context = %{views: views, capabilities: capabilities, timezone: timezone}

      if table.storage_mode == :physical do
        shard = BaseRepo.shard!()

        BaseRepo.run(
          shard,
          fn ->
            with {:ok, current} <- Physical.state(table),
                 do: fun.(current, limits, definitions, context)
          end,
          read_only: true,
          statement_timeout_ms: limits["statement_timeout_ms"],
          timezone: timezone
        )
      else
        fun.(table, limits, definitions, context)
      end
    else
      nil -> {:error, :not_found}
      :error -> {:error, :not_found}
      error -> error
    end
  end

  defp broadcast_result(id, result) do
    notify(id, "changed", Map.take(result, [:data_version, :changed_ids, :deleted_ids, :resync]))

    Enum.each(Map.get(result, :related, []), fn item ->
      notify(
        item.id,
        "changed",
        Map.take(item, [:data_version, :changed_ids, :deleted_ids, :resync])
      )
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

defmodule Ankole.Pod.Bases.Capabilities do
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
