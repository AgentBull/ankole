defmodule Ankole.Repo do
  @moduledoc """
  PostgreSQL state and the calling process's tenant context.
  """

  use Ecto.Repo,
    otp_app: :ankole,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query, only: [where: 3]

  @tenant_key {__MODULE__, :tenant}

  # Schema writes do not call prepare_query/3.
  for operation <- [
        :insert,
        :insert!,
        :insert_or_update,
        :insert_or_update!,
        :update,
        :update!,
        :delete,
        :delete!
      ] do
    defoverridable [{operation, 2}]

    @impl true
    def unquote(operation)(value, opts) do
      super(scope_write(unquote(operation), value, opts), opts)
    end
  end

  defoverridable insert_all: 3

  @impl true
  def insert_all(schema_or_source, entries, opts) do
    if is_list(entries) and
         tenancy({schema_or_source, schema_module(schema_or_source)}) == :tenant do
      tenant = Keyword.get(opts, :tenant, Process.get(@tenant_key))
      Enum.each(entries, &check_write_tenant!(&1[:tenant_id], tenant, false))
    end

    super(schema_or_source, entries, opts)
  end

  @doc "Sets the tenant for a process that serves only that tenant."
  def put_tenant_id(nil) do
    put_context(nil)
    :ok
  end

  def put_tenant_id(tenant_id) do
    {:ok, tenant_id} = Ecto.UUID.cast(tenant_id)
    put_context({:id, tenant_id})
    :ok
  end

  @doc "Returns the current tenant, or nil outside a tenant context."
  def tenant_id do
    case Process.get(@tenant_key) do
      {:id, tenant_id} -> tenant_id
      _ -> nil
    end
  end

  @doc "Returns the current tenant or raises when no tenant is selected."
  def tenant_id! do
    tenant_id() || raise Ankole.TenantContextMissing
  end

  @doc "Runs a function in a tenant and restores the caller's context."
  def with_tenant(tenant_id, fun) when is_function(fun, 0) do
    {:ok, tenant_id} = Ecto.UUID.cast(tenant_id)
    with_context({:id, tenant_id}, fun)
  end

  @doc "Explicitly permits a function to query all tenants."
  def across_tenants(fun) when is_function(fun, 0), do: with_context(:all, fun)

  @doc "Runs a site function without an inherited tenant context."
  def without_tenant(fun) when is_function(fun, 0), do: with_context(nil, fun)

  @doc "Captures the current context for a child process."
  def bind_tenant(fun) when is_function(fun, 0) do
    tenant = Process.get(@tenant_key)
    fn -> with_context(tenant, fun) end
  end

  @impl true
  def default_options(_operation), do: [tenant: Process.get(@tenant_key)]

  @impl true
  def prepare_query(_operation, query, opts) do
    if opts[:ecto_query] == :schema_migration do
      {query, opts}
    else
      {scope_query(query, opts[:tenant]), opts}
    end
  end

  @doc "Escapes PostgreSQL LIKE wildcard characters for a literal pattern fragment."
  @spec escape_like(String.t()) :: String.t()
  def escape_like(text) when is_binary(text) do
    String.replace(text, ~r/([\\%_])/, "\\\\\\1")
  end

  defp with_context(context, fun) do
    previous = Process.get(@tenant_key)
    previous_log_tenant = Keyword.get(Logger.metadata(), :tenant_id)
    put_context(context)

    try do
      fun.()
    after
      put_context(previous)
      Logger.metadata(tenant_id: previous_log_tenant)
    end
  end

  defp put_context(nil) do
    Process.delete(@tenant_key)
    Logger.metadata(tenant_id: nil)
  end

  defp put_context(context) do
    Process.put(@tenant_key, context)
    Logger.metadata(tenant_id: if(match?({:id, _}, context), do: elem(context, 1)))
  end

  defp scope_write(operation, %Ecto.Changeset{data: data} = changeset, opts) do
    if tenancy({data.__meta__.source, data.__struct__}) == :tenant do
      tenant = Keyword.get(opts, :tenant, Process.get(@tenant_key))

      inserting =
        operation in [:insert, :insert!, :insert_or_update, :insert_or_update!] and
          data.__meta__.state == :built

      check_write_tenant!(data.tenant_id, tenant, inserting)
      check_write_tenant!(Ecto.Changeset.get_field(changeset, :tenant_id), tenant, inserting)

      if inserting do
        case tenant do
          {:id, tenant_id} -> Ecto.Changeset.put_change(changeset, :tenant_id, tenant_id)
          :all -> changeset
        end
      else
        %{changeset | filters: Map.put(changeset.filters, :tenant_id, data.tenant_id)}
      end
    else
      changeset
    end
  end

  defp scope_write(operation, data, opts),
    do: scope_write(operation, Ecto.Changeset.change(data), opts)

  defp check_write_tenant!(_tenant_id, :all, _inserting), do: :ok
  defp check_write_tenant!(_tenant_id, nil, _inserting), do: raise(Ankole.TenantContextMissing)
  defp check_write_tenant!(nil, {:id, _tenant_id}, true), do: :ok
  defp check_write_tenant!(tenant_id, {:id, tenant_id}, _inserting), do: :ok

  defp check_write_tenant!(_tenant_id, _tenant, _inserting),
    do: raise(ArgumentError, "write tenant does not match the selected tenant")

  defp schema_module(source) when is_binary(source), do: nil
  defp schema_module(schema), do: schema

  # Query expressions own their subqueries, including EXISTS and IN. Traverse
  # those expressions even when the outer source is a site table.
  defp scope_query(query, tenant) do
    query = %{
      query
      | from: scope_source(query.from, tenant),
        joins: Enum.map(query.joins, &scope_join(&1, tenant)),
        wheres: Enum.map(query.wheres, &scope_expression(&1, tenant)),
        havings: Enum.map(query.havings, &scope_expression(&1, tenant)),
        select: scope_expression(query.select, tenant),
        order_bys: Enum.map(query.order_bys, &scope_expression(&1, tenant)),
        group_bys: Enum.map(query.group_bys, &scope_expression(&1, tenant)),
        distinct: scope_expression(query.distinct, tenant),
        windows:
          Enum.map(query.windows, fn {name, expression} ->
            {name, scope_expression(expression, tenant)}
          end),
        combinations:
          Enum.map(query.combinations, fn {operation, nested} ->
            {operation, scope_query(nested, tenant)}
          end),
        with_ctes: scope_ctes(query.with_ctes, tenant)
    }

    case tenancy(query.from.source) do
      :site -> check_tenant_joins(query, tenant)
      :subquery -> check_tenant_joins(query, tenant)
      :tenant -> scope_tenant(query, tenant)
    end
  end

  defp check_tenant_joins(query, :all), do: query

  defp check_tenant_joins(query, tenant) do
    case {tenant, Enum.any?(query.joins, &tenant_join?(&1.source, query.with_ctes))} do
      {nil, true} ->
        raise Ankole.TenantContextMissing, query: query

      {_, true} ->
        raise ArgumentError,
              "tenant joins require a tenant-owned root or a tenant-scoped subquery; " <>
                "use Repo.across_tenants/1 for an explicit cross-tenant query"

      _ ->
        query
    end
  end

  # Oban fetches jobs through a quoted CTE reference. Its query is scoped above.
  defp tenant_join?({:fragment, _, [{:raw, source}]}, %{queries: queries}) do
    not Enum.any?(queries, fn
      {name, _opts, %Ecto.Query{}} -> source in [name, ~s("#{name}")]
      _other -> false
    end)
  end

  defp tenant_join?(source, _ctes), do: tenancy(source) == :tenant

  defp scope_tenant(query, {:id, tenant_id}),
    do: where(query, [row], field(row, :tenant_id) == type(^tenant_id, Ecto.UUID))

  defp scope_tenant(query, :all), do: query
  defp scope_tenant(query, nil), do: raise(Ankole.TenantContextMissing, query: query)

  defp scope_tenant(_query, tenant),
    do: raise(ArgumentError, "invalid tenant query option: #{inspect(tenant)}")

  defp tenancy(%Ecto.SubQuery{}), do: :subquery
  defp tenancy({_source, Ecto.Migration.SchemaMigration}), do: :site
  defp tenancy({_source, Oban.Job}), do: :site
  defp tenancy({source, nil}) when source in ["oban_jobs", "oban_peers"], do: :site
  defp tenancy({_source, nil}), do: :tenant

  defp tenancy({_source, schema}) when is_atom(schema) do
    if Code.ensure_loaded?(schema) and function_exported?(schema, :__tenancy__, 0) do
      schema.__tenancy__()
    else
      raise ArgumentError, "#{inspect(schema)} has no tenancy declaration"
    end
  end

  defp tenancy(_source), do: :tenant

  defp scope_source(%{source: %Ecto.SubQuery{} = subquery} = expression, tenant),
    do: %{expression | source: %{subquery | query: scope_query(subquery.query, tenant)}}

  defp scope_source(expression, _tenant), do: expression

  defp scope_join(join, tenant),
    do: %{scope_source(join, tenant) | on: scope_expression(join.on, tenant)}

  defp scope_expression(%{subqueries: subqueries} = expression, tenant),
    do: %{
      expression
      | subqueries:
          Enum.map(subqueries, fn subquery ->
            %{subquery | query: scope_query(subquery.query, tenant)}
          end)
    }

  defp scope_expression(expression, _tenant), do: expression

  defp scope_ctes(nil, _tenant), do: nil

  defp scope_ctes(ctes, tenant),
    do: %{
      ctes
      | queries:
          Enum.map(ctes.queries, fn
            {name, opts, %Ecto.Query{} = query} -> {name, opts, scope_query(query, tenant)}
            other -> other
          end)
    }
end
