defmodule Ankole.Connectors.Databases do
  @moduledoc """
  Database connections: connection-level authorization, the rebuildable
  catalog cache, and the read-query interface shared by tools and Brain.

  A database adapter is a `connectors.connector` module that exports
  `read_query/4`, `fetch_catalog/3`, and `mark_catalog/2`. The adapter owns the
  engine protocol, its execution guards, and the sensitivity rules; Connectors
  owns credentials, AuthZ, and the cache.
  """
  require Ash.Query
  require Ash.Sort
  alias Ankole.Connectors.{Credentials, DbCatalogColumn, DbCatalogTable, Registry, Store}
  alias Ankole.Repo

  @action "query"
  @access_description "Connection access chosen in the connection settings"
  @search_columns 50

  def database?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :read_query, 4)

  def adapter(%{plugin_id: plugin_id}) do
    with {:ok, module} <- Registry.adapter(plugin_id),
         true <- database?(module) do
      {:ok, module}
    else
      _ -> {:error, :not_database_connection}
    end
  end

  def resource(%{id: id}), do: "connector_connection:" <> id

  @doc "Resolves a database tool call. Database connections hold only application credentials."
  def resolve_call(principal, config) do
    with :ok <- active(config),
         :ok <- authorize(principal, config) do
      {:ok,
       %{
         actor: principal,
         auth_config: config,
         account: nil,
         access_token: nil,
         external_user_id: nil
       }}
    end
  end

  defp active(%{status: "active"}), do: :ok
  defp active(_), do: {:error, :connection_disabled}

  def authorize(%{uid: uid}, config) do
    case Ankole.AuthZ.authorize(uid, resource(config), @action) do
      :ok -> :ok
      _ -> {:error, :connection_forbidden}
    end
  end

  @doc """
  Runs one read-only statement on a database connection and returns the
  adapter's evidence envelope. `actor` is an `Ankole.AuthZ.Actor` or a
  Principal; exporting rows to a Pod file requires an `Ankole.AuthZ.Actor`.
  """
  def run_read_query(actor, connection, sql, params \\ [], opts \\ []) do
    principal = principal(actor)

    with :ok <- Store.member(principal),
         {:ok, config} <- Store.get_auth_config(connection),
         {:ok, adapter} <- adapter(config),
         {:ok, context} <- resolve_call(principal, config) do
      adapter.read_query(%{context | actor: actor}, sql, params, opts)
    end
  end

  defp principal(%Ankole.AuthZ.Actor{principal: principal}), do: principal
  defp principal(principal), do: principal

  ## Connection access

  @doc """
  Replaces the connection's `query` grants, clears the cached samples of
  columns that the saved settings now make sensitive, and queues a catalog
  refresh in the caller's transaction. A new connection without a choice is available to
  all members and AI colleagues; an update without a choice keeps the grants.
  """
  def saved_in_tx(config, access, created?) do
    case adapter(config) do
      {:ok, adapter} ->
        with :ok <- put_access_in_tx(config, access || if(created?, do: %{"mode" => "members"})),
             :ok <- clear_sensitive_samples_in_tx(config, adapter),
             {:ok, _} <-
               Oban.insert(
                 Ankole.Connectors.Jobs.RefreshDatabaseCatalog.new(%{
                   "auth_config_id" => config.id
                 })
               ),
             do: :ok

      _ ->
        :ok
    end
  end

  # A column that the saved exclusions now name loses its cached samples in
  # the save transaction; the queued refresh rebuilds the other profiles.
  defp clear_sensitive_samples_in_tx(config, adapter) do
    tables =
      DbCatalogTable
      |> Ash.Query.filter(auth_config_id == ^config.id)
      |> Ankole.Ash.read!()

    columns = columns_by_table(Enum.map(tables, & &1.id))

    cached =
      Enum.map(tables, fn table ->
        %{
          "schema" => table.schema_name,
          "name" => table.table_name,
          "columns" =>
            columns
            |> Map.get(table.id, [])
            |> Enum.reject(& &1.sensitive)
            |> Enum.map(&Map.put(column_summary(&1), "id", &1.id))
        }
      end)

    ids =
      for table <- adapter.mark_catalog(config, cached),
          column <- table["columns"],
          column["sensitive"],
          do: column["id"]

    if ids == [] do
      :ok
    else
      with {:ok, _} <-
             DbCatalogColumn
             |> Ash.Query.filter(id in ^ids)
             |> Ankole.Ash.update_where(:mask),
           do: :ok
    end
  end

  defp put_access_in_tx(_config, nil), do: :ok

  defp put_access_in_tx(config, access) do
    with {:ok, desired} <- desired_owners(access) do
      existing = grants(config)
      stale = Enum.reject(existing, &(owner(&1) in desired))
      missing = desired -- Enum.map(existing, &owner/1)

      with :ok <- each(stale, &Ankole.AuthZ.Grants.delete_permission_grant(&1.id)) do
        each(missing, fn owner ->
          Ankole.AuthZ.Grants.upsert_permission_grant(
            Map.merge(owner, %{
              resource_pattern: resource(config),
              action: @action,
              condition: "true",
              description: @access_description,
              metadata: %{}
            })
          )
        end)
      end
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp desired_owners(%{"mode" => "members"}) do
    with {:ok, humans} <- Ankole.AuthZ.Root.ensure_all_humans_group(),
         {:ok, agents} <- Ankole.AuthZ.Root.ensure_all_agents_group(),
         do: {:ok, [%{group_id: humans.id}, %{group_id: agents.id}]}
  end

  defp desired_owners(%{"mode" => "restricted"} = access) do
    groups = access["group_ids"] || []
    principals = access["principal_uids"] || []

    if Enum.all?(groups ++ principals, &(is_binary(&1) and &1 != "")),
      do:
        {:ok,
         Enum.map(Enum.uniq(groups), &%{group_id: &1}) ++
           Enum.map(Enum.uniq(principals), &%{principal_uid: &1})},
      else: {:error, :invalid_connection_access}
  end

  defp desired_owners(_), do: {:error, :invalid_connection_access}

  defp owner(%{group_id: id}) when is_binary(id), do: %{group_id: id}
  defp owner(%{principal_uid: uid}), do: %{principal_uid: uid}

  defp grants(config) do
    Ankole.AuthZ.list_grants!(
      query: [filter: [resource_pattern: resource(config), action: @action]]
    )
  end

  @doc "Projects the connection's access choice from its AuthZ grants; nil for other connections."
  def access(config) do
    with {:ok, _} <- adapter(config) do
      grants = grants(config)

      case Ankole.AuthZ.get_principal_group("all_humans") do
        {:ok, %{id: humans}} when is_binary(humans) ->
          if Enum.any?(grants, &(&1.group_id == humans)),
            do: %{"mode" => "members"},
            else: restricted(grants)

        _ ->
          restricted(grants)
      end
    else
      _ -> nil
    end
  end

  defp restricted(grants),
    do: %{
      "mode" => "restricted",
      "group_ids" => grants |> Enum.map(& &1.group_id) |> Enum.reject(&is_nil/1),
      "principal_uids" => grants |> Enum.map(& &1.principal_uid) |> Enum.reject(&is_nil/1)
    }

  ## Catalog cache

  @doc "Rebuilds a connection's catalog cache now. Requires Pod administrator permission."
  def refresh(actor, connection) do
    with :ok <- Store.admin(actor),
         {:ok, config} <- Store.get_auth_config(connection),
         do: refresh_config(config)
  end

  @doc "Rebuilds the catalog cache of one stored connection; the refresh job calls it."
  def refresh_config(config) do
    with {:ok, adapter} <- adapter(config),
         :ok <- active(config),
         {:ok, secret} <- Credentials.secret(config),
         {:ok, %{"tables" => tables, "complete" => complete?}} <-
           adapter.fetch_catalog(config, secret, []) do
      replace_catalog(config, tables, complete?)
    end
  end

  @doc """
  Replaces the connection's cached catalog. `complete?` is false when the
  adapter stopped at the `catalog_tables` budget; such a snapshot reports
  missing columns of the tables it holds but never infers deleted tables.
  """
  def replace_catalog(config, tables, complete?) do
    fetched_at = DateTime.utc_now()

    Repo.transact_top_level(fn ->
      Ankole.AdvisoryLock.lock!(Repo, "connector_db_catalog:#{Repo.tenant_id!()}:#{config.id}")

      rows =
        Enum.map(tables, fn table ->
          {Ankole.Kernel.gen_uuid_v7(), table}
        end)

      previous = catalog_snapshot(config)

      with {:ok, _} <-
             DbCatalogTable
             |> Ash.Query.filter(auth_config_id == ^config.id)
             |> Ankole.Ash.destroy_where(:destroy),
           {:ok, _} <-
             Ankole.Ash.create_all(
               Enum.map(rows, fn {id, table} ->
                 table_input(config, id, table, fetched_at, complete?)
               end),
               DbCatalogTable,
               :create
             ),
           {:ok, _} <-
             Ankole.Ash.create_all(
               Enum.flat_map(rows, fn {id, table} ->
                 Enum.map(table["columns"] || [], &column_input(id, &1))
               end),
               DbCatalogColumn,
               :create
             ),
           :ok <- report_missing(config, previous, tables, complete?) do
        {:ok,
         %{"table_count" => length(rows), "fetched_at" => fetched_at, "complete" => complete?}}
      end
    end)
  end

  defp catalog_snapshot(config) do
    tables =
      DbCatalogTable
      |> Ash.Query.filter(auth_config_id == ^config.id)
      |> Ankole.Ash.read!()

    ids = Enum.map(tables, & &1.id)

    columns =
      DbCatalogColumn
      |> Ash.Query.filter(table_id in ^ids)
      |> Ankole.Ash.read!()
      |> Enum.group_by(& &1.table_id, & &1.column_name)

    Map.new(tables, &{{&1.schema_name, &1.table_name}, Map.get(columns, &1.id, [])})
  end

  # Brain marks published metrics that read a table or column this refresh no longer finds.
  defp report_missing(config, previous, tables, complete?) do
    current =
      Map.new(tables, fn table ->
        {{table["schema"] || "", table["name"]}, Enum.map(table["columns"] || [], & &1["name"])}
      end)

    missing =
      Enum.flat_map(previous, fn {{schema, name} = key, columns} ->
        base =
          if schema == "", do: %{"table" => name}, else: %{"table" => name, "schema" => schema}

        case Map.fetch(current, key) do
          :error when complete? -> [base]
          :error -> []
          {:ok, now} -> Enum.map(columns -- now, &Map.put(base, "column", &1))
        end
      end)

    if missing == [],
      do: :ok,
      else: Ankole.Brain.connector_columns_missing_in_tx(config.slug, missing)
  end

  defp table_input(config, id, table, fetched_at, complete?) do
    columns = table["columns"] || []

    %{
      id: id,
      auth_config_id: config.id,
      schema_name: table["schema"] || "",
      table_name: table["name"],
      table_kind: table["kind"] || "table",
      comment: table["comment"],
      row_estimate: table["row_estimate"],
      primary_key: table["primary_key"] || [],
      sparse_order_key: table["sparse_order_key"] || [],
      query_count: table["query_count"],
      search_text:
        Enum.join(
          [table["schema"], table["name"], table["comment"]] ++
            Enum.flat_map(columns, &[&1["name"], &1["comment"]]),
          " "
        ),
      fetched_at: fetched_at,
      catalog_complete: complete?
    }
  end

  defp column_input(table_id, column) do
    %{
      table_id: table_id,
      column_name: column["name"],
      ordinal: column["ordinal"] || 0,
      data_type: column["type"] || "unknown",
      nullable: column["nullable"] != false,
      comment: column["comment"],
      is_primary_key: column["primary_key"] == true,
      is_unique: column["unique"] == true,
      sparse_order_key: column["sparse_order_key"] == true,
      foreign_key: column["foreign_key"],
      sensitive: column["sensitive"] == true,
      profile: masked_profile(column)
    }
  end

  # The adapter skips sensitive columns while sampling; the cache drops any
  # value-bearing field for them again so a raw sample never persists.
  defp masked_profile(%{"sensitive" => true, "profile" => profile}) when is_map(profile),
    do: Map.drop(profile, ["sample_values", "min", "max"])

  defp masked_profile(column), do: column["profile"]

  @doc """
  Summarizes the connection's last catalog refresh as its cached table count
  and whether that refresh held every table. Returns nil for a connection
  that is not a database or has no cached tables.
  """
  def catalog(config) do
    with {:ok, _} <- adapter(config),
         query = Ash.Query.filter(DbCatalogTable, auth_config_id == ^config.id),
         {:ok, %{catalog_complete: complete?}} <-
           query |> Ash.Query.limit(1) |> Ankole.Ash.read_one() do
      %{table_count: Ankole.Ash.count!(query), complete: complete?}
    else
      _ -> nil
    end
  end

  @doc """
  Searches a connection's cached tables and columns with BM25; a blank query
  lists the most used tables. `complete` is false when the last refresh
  stopped at the `catalog_tables` budget, so a table absent from the result
  may still exist in the external database.
  """
  def search_catalog(config, query, limit) do
    base =
      DbCatalogTable
      |> Ash.Query.filter(auth_config_id == ^config.id)
      |> Ash.Query.limit(limit)

    query = String.trim(query || "")

    base =
      if query == "",
        do:
          Ash.Query.sort(base, [
            {Ash.Sort.expr_sort(fragment("coalesce(?, -1)", query_count), :integer), :desc},
            schema_name: :asc,
            table_name: :asc
          ]),
        else:
          base
          |> Ash.Query.filter(fragment("? @@@ pdb.match(?)", search_text, ^query))
          |> Ash.Query.sort([{Ash.Sort.expr_sort(fragment("pdb.score(?)", id), :float), :desc}])

    with {:ok, tables} <- Ankole.Ash.read(base) do
      columns = columns_by_table(Enum.map(tables, & &1.id))

      {:ok,
       %{
         "tables" =>
           Enum.map(tables, fn table ->
             table
             |> table_summary()
             |> Map.put(
               "columns",
               columns
               |> Map.get(table.id, [])
               |> Enum.take(@search_columns)
               |> Enum.map(& &1.column_name)
             )
           end),
         "complete" => not match?(%{complete: false}, catalog(config))
       }}
    end
  end

  @doc "Reads one cached table with its columns, key properties, and masked profiles."
  def describe_table(config, schema, table) do
    query =
      DbCatalogTable
      |> Ash.Query.filter(auth_config_id == ^config.id and table_name == ^table)

    query = if schema, do: Ash.Query.filter(query, schema_name == ^schema), else: query

    case Ankole.Ash.read(query) do
      {:ok, [row]} ->
        columns = columns_by_table([row.id]) |> Map.get(row.id, [])

        {:ok,
         row
         |> table_summary()
         |> Map.merge(%{
           "primary_key" => row.primary_key,
           "sparse_order_key" => row.sparse_order_key,
           "fetched_at" => DateTime.to_iso8601(row.fetched_at),
           "columns" => Enum.map(columns, &column_summary/1)
         })}

      {:ok, []} ->
        {:error, :table_not_found}

      {:ok, rows} ->
        {:error,
         %{
           code: "table_ambiguous",
           message: "Name the schema of this table.",
           schemas: Enum.map(rows, & &1.schema_name),
           retryable: false
         }}

      error ->
        error
    end
  end

  defp columns_by_table([]), do: %{}

  defp columns_by_table(ids) do
    DbCatalogColumn
    |> Ash.Query.filter(table_id in ^ids)
    |> Ash.Query.sort(ordinal: :asc)
    |> Ankole.Ash.read!()
    |> Enum.group_by(& &1.table_id)
  end

  defp table_summary(row),
    do: %{
      "schema" => row.schema_name,
      "table" => row.table_name,
      "kind" => row.table_kind,
      "comment" => row.comment,
      "row_estimate" => row.row_estimate,
      "query_count" => row.query_count
    }

  defp column_summary(column),
    do: %{
      "name" => column.column_name,
      "type" => column.data_type,
      "nullable" => column.nullable,
      "comment" => column.comment,
      "primary_key" => column.is_primary_key,
      "unique" => column.is_unique,
      "sparse_order_key" => column.sparse_order_key,
      "foreign_key" => column.foreign_key,
      "sensitive" => column.sensitive,
      "profile" => column.profile
    }
end
