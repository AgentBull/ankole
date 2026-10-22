defmodule Ankole.Ash do
  @moduledoc """
  Runs Ash actions in the calling process's tenant context.

  The functions select the tenant from `Ankole.Repo`, give declared errors
  (`Ankole.Errors`), and decode bulk results. Code outside the owning domain
  calls the domain's code interface instead.
  """

  alias Ankole.Errors.Invalid.Stale

  @doc """
  Gives the default options of every domain code interface function.

  `Ankole.Ash.Transformers.DomainDefaults` sets this function on each define.
  `Ankole.Repo` owns the tenant; this function only reads it.
  """
  def default_options, do: [tenant: Ankole.Repo.tenant_id()]

  def for_create(resource, action, attrs, opts \\ []),
    do: Ash.Changeset.for_create(resource, action, attrs, options(resource, opts))

  def for_update(record, action, attrs, opts \\ []),
    do: Ash.Changeset.for_update(record, action, attrs, options(record.__struct__, opts))

  def create(%Ash.Changeset{} = changeset) do
    changeset
    |> Ash.create(options(changeset.resource, tenant: changeset.tenant))
    |> Ankole.Errors.boundary_result()
  end

  def create(resource, action, attrs, opts \\ []),
    do:
      resource
      |> for_create(action, attrs, opts)
      |> Ash.create(options(resource, opts))
      |> Ankole.Errors.boundary_result()

  def update(%Ash.Changeset{} = changeset) do
    changeset
    |> Ash.update(options(changeset.resource, tenant: changeset.tenant))
    |> Ankole.Errors.boundary_result()
  end

  def update(record, action, attrs, opts \\ []) do
    record
    |> for_update(action, attrs, opts)
    |> Ash.update(options(record.__struct__, opts))
    |> Ankole.Errors.boundary_result()
  end

  def destroy(record, action, opts \\ []) do
    options = options(record.__struct__, opts)

    record
    |> Ash.Changeset.for_destroy(action, %{}, options)
    |> Ash.destroy(Keyword.put(options, :return_destroyed?, true))
    |> Ankole.Errors.boundary_result()
  end

  @doc """
  Reads a query in the caller's tenant.

  A query with `Ash.Query.lock/2` gives `lock_identity:` for the lock-order
  check: `{table, keys}` names the rows before the read, and
  `{:rows, table, key}` checks the keys of the rows that the read locked.
  """
  def read(query, opts \\ []) do
    {identity, opts} = Keyword.pop(opts, :lock_identity)

    locked_read(identity, fn ->
      query
      |> Ash.read(options(query_resource(query), opts))
      |> Ankole.Errors.boundary_result()
    end)
  end

  def read!(query, opts \\ []) do
    {identity, opts} = Keyword.pop(opts, :lock_identity)

    locked_read(identity, fn ->
      Ash.read!(query, options(query_resource(query), opts))
    end)
  end

  def read_one(query, opts \\ []) do
    {identity, opts} = Keyword.pop(opts, :lock_identity)

    locked_read(identity, fn ->
      query
      |> Ash.read_one(options(query_resource(query), opts))
      |> Ankole.Errors.boundary_result()
    end)
  end

  def read_one!(query, opts \\ []) do
    {identity, opts} = Keyword.pop(opts, :lock_identity)

    locked_read(identity, fn ->
      Ash.read_one!(query, options(query_resource(query), opts))
    end)
  end

  def aggregate!(query, aggregates, opts \\ []),
    do: Ash.aggregate!(query, aggregates, options(query_resource(query), opts))

  def max!(query, field, opts \\ []),
    do: Ash.max!(query, field, options(query_resource(query), opts))

  def run_action(resource, action, args, opts \\ []) do
    options = options(resource, opts)

    resource
    |> Ash.ActionInput.for_action(action, args, options)
    |> Ash.run_action(options)
    |> Ankole.Errors.boundary_result()
  end

  def bulk_create(inputs, resource, action, opts \\ []),
    do: Ash.bulk_create(inputs, resource, action, bulk_options(resource, opts))

  def bulk_update(query_or_stream, action, input, opts \\ []),
    do:
      Ash.bulk_update(
        query_or_stream,
        action,
        input,
        bulk_options(bulk_resource(query_or_stream, opts), opts)
      )

  def bulk_destroy(query_or_stream, action, input, opts \\ []),
    do:
      Ash.bulk_destroy(
        query_or_stream,
        action,
        input,
        bulk_options(bulk_resource(query_or_stream, opts), opts)
      )

  @doc """
  Runs an atomic update on one row in one statement.

  The subject is a record or a query that selects at most one row. When no
  current row matches, the result is an `Ash.Error.Invalid` error with
  `Ankole.Errors.Invalid.Stale`.
  """
  def update_atomic(record_or_query, action, input \\ %{}, opts \\ []) do
    query = row_query(record_or_query)

    case update_where(query, action, input, opts) do
      {:ok, [record]} ->
        {:ok, record}

      {:ok, []} ->
        {:error,
         Ash.Error.to_error_class(Stale.exception(resource: query.resource, filter: query.filter))}

      {:ok, _records} ->
        raise ArgumentError,
              "update_atomic/4 changed more than one #{inspect(query.resource)} row"

      {:error, _error} = error ->
        error
    end
  end

  @doc "Runs an update on every row that a query selects and gives the changed rows."
  def update_where(query, action, input \\ %{}, opts \\ []) do
    query
    |> bulk_update(action, input, bulk_where_options(opts))
    |> bulk_records()
  end

  @doc "Runs a destroy on every row that a query selects and gives the destroyed rows."
  def destroy_where(query, action, opts \\ []) do
    query
    |> bulk_destroy(action, %{}, bulk_where_options(opts))
    |> bulk_records()
  end

  @doc """
  Runs a `create_if_absent` action and tells whether it inserted the row.

  The result is `{:ok, record, :created}` or `{:ok, record, :existing}`. An
  existing row of another tenant gives `Ankole.Errors.Invalid.Stale`.
  """
  def insert_if_absent(resource, action, attrs, opts \\ []) do
    with {:ok, record} <- create(resource, action, attrs, opts) do
      if Ash.Resource.get_metadata(record, :upsert_skipped),
        do: {:ok, record, :existing},
        else: {:ok, record, :created}
    end
  end

  @doc "Projects validation failures without records, input values, or internal error paths."
  def validation_details(%Ash.Changeset{errors: errors}), do: validation_details(errors)
  def validation_details(%Ash.Error.Invalid{errors: errors}), do: validation_details(errors)

  def validation_details(errors) when is_list(errors),
    do: errors |> Enum.flat_map(&validation_details/1) |> Enum.uniq()

  def validation_details(%module{field: field} = error)
      when module in [Ash.Error.Changes.InvalidAttribute, Ash.Error.Changes.InvalidArgument] do
    [validation_detail(field, validation_message(error))]
  end

  def validation_details(%Ash.Error.Changes.Required{field: field}),
    do: [validation_detail(field, "is required")]

  def validation_details(%Ash.Error.Changes.InvalidRelationship{relationship: field} = error),
    do: [validation_detail(field, validation_message(error))]

  def validation_details(%Ash.Error.Changes.InvalidChanges{fields: fields} = error) do
    Enum.map(fields || [nil], &validation_detail(&1, validation_message(error)))
  end

  def validation_details(%module{field: field})
      when module in [
             Ankole.Errors.Invalid.StatusTransition,
             AshStateMachine.Errors.NoMatchingTransition,
             AshStateMachine.Errors.InvalidInitialState
           ],
      do: [validation_detail(field, "does not permit this state transition")]

  def validation_details(_error), do: [validation_detail(nil, "request is invalid")]

  defp validation_detail(field, message),
    do: %{
      path: if(is_atom(field) and not is_nil(field), do: Atom.to_string(field), else: ""),
      message: message
    }

  defp validation_message(%{message: "must be in %{list}"} = error),
    do: enum_message(Ankole.Attrs.get(Map.new(error.vars || []), :list))

  defp validation_message(%{message: "atom must be one of %{atom_list}, got: %{value}"} = error),
    do: enum_message(Ankole.Attrs.get(Map.new(error.vars || []), :atom_list))

  defp validation_message(%{message: "must be one of %{values}"} = error),
    do: enum_message(Ankole.Attrs.get(Map.new(error.vars || []), :values))

  defp validation_message(%{message: "must match the pattern %{regex}"}),
    do: "has an invalid format"

  defp validation_message(%{message: message} = error) when is_binary(message) do
    message =
      Enum.reduce(Map.get(error, :vars) || [], message, fn
        {name, _value}, acc when name in [:value, "value"] ->
          acc

        {name, value}, acc when is_number(value) ->
          String.replace(acc, "%{#{name}}", to_string(value))

        _other, acc ->
          acc
      end)

    if String.contains?(message, "%{"), do: "is invalid", else: message
  end

  defp validation_message(_error), do: "is invalid"

  defp enum_message(values) when is_list(values),
    do: "must be one of: " <> Enum.map_join(values, ", ", &to_string/1)

  defp enum_message(values) when is_binary(values), do: "must be one of: " <> values

  defp enum_message(_values), do: "is not an allowed value"

  defp locked_read(nil, fun), do: fun.()

  defp locked_read({:rows, table, key} = identity, fun) do
    result = Ankole.LockOrder.with_identity(identity, fun)

    rows =
      case result do
        {:ok, rows} -> List.wrap(rows)
        {:error, _error} -> []
        rows -> List.wrap(rows)
      end

    Ankole.LockOrder.check_rows(table, Enum.map(rows, &Map.fetch!(&1, key)))
    result
  end

  defp locked_read(identity, fun), do: Ankole.LockOrder.with_identity(identity, fun)

  defp row_query(%Ash.Query{} = query), do: query

  defp row_query(%resource{} = record) do
    key = record |> Map.take(Ash.Resource.Info.primary_key(resource)) |> Enum.to_list()
    Ash.Query.do_filter(resource, key)
  end

  defp bulk_where_options(opts),
    do:
      [strategy: [:atomic], return_errors?: true]
      |> Keyword.merge(opts)
      |> Keyword.put(:return_records?, true)

  defp bulk_records(%Ash.BulkResult{status: :success, records: records}), do: {:ok, records}

  defp bulk_records(%Ash.BulkResult{errors: errors}),
    do: {:error, errors |> Ash.Error.to_error_class() |> Ankole.Errors.shape_errors()}

  defp options(resource, opts) do
    tenant =
      case resource.__tenancy__() do
        :tenant -> Ankole.Repo.tenant_id!()
        :site -> nil
      end

    if Keyword.get(opts, :tenant, tenant) != tenant,
      do: raise(ArgumentError, "action tenant does not match the selected resource scope")

    Keyword.merge([tenant: tenant, authorize?: false], opts)
  end

  defp query_resource(%Ash.Query{resource: resource}), do: resource
  defp query_resource(resource) when is_atom(resource), do: resource

  defp bulk_resource(%Ash.Query{resource: resource}, _opts), do: resource
  defp bulk_resource(resource, _opts) when is_atom(resource), do: resource
  defp bulk_resource(_stream, opts), do: Keyword.fetch!(opts, :resource)

  defp bulk_options(resource, opts) do
    resource
    |> options(opts)
    |> Keyword.put_new(:transaction, false)
    |> Keyword.put(:max_concurrency, 1)
  end
end
