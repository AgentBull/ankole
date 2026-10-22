defmodule Ankole.Ash do
  @moduledoc "Runs Ash actions in the calling process's tenant context."

  def for_create(resource, action, attrs, opts \\ []),
    do: Ash.Changeset.for_create(resource, action, attrs, options(resource, opts))

  def for_update(record, action, attrs, opts \\ []),
    do: Ash.Changeset.for_update(record, action, attrs, options(record.__struct__, opts))

  def create(%Ash.Changeset{} = changeset) do
    changeset
    |> Ash.create(options(changeset.resource, tenant: changeset.tenant))
    |> normalize_result()
  end

  def create(resource, action, attrs, opts \\ []),
    do:
      resource
      |> for_create(action, attrs, opts)
      |> Ash.create(options(resource, opts))
      |> normalize_result()

  def update(%Ash.Changeset{} = changeset) do
    changeset
    |> Ash.update(options(changeset.resource, tenant: changeset.tenant))
    |> normalize_result()
  end

  def update(record, action, attrs, opts \\ []) do
    record
    |> for_update(action, attrs, opts)
    |> Ash.update(options(record.__struct__, opts))
    |> normalize_result()
  end

  def destroy(record, action, opts \\ []) do
    options = options(record.__struct__, opts)

    record
    |> Ash.Changeset.for_destroy(action, %{}, options)
    |> Ash.destroy(Keyword.put(options, :return_destroyed?, true))
    |> normalize_result()
  end

  def read(query, opts \\ []),
    do:
      query
      |> Ash.read(options(query_resource(query), opts))
      |> normalize_result()

  def read!(query, opts \\ []),
    do: Ash.read!(query, options(query_resource(query), opts))

  def read_one(query, opts \\ []),
    do:
      query
      |> Ash.read_one(options(query_resource(query), opts))
      |> normalize_result()

  def read_one!(query, opts \\ []),
    do: Ash.read_one!(query, options(query_resource(query), opts))

  def aggregate!(query, aggregates, opts \\ []),
    do: Ash.aggregate!(query, aggregates, options(query_resource(query), opts))

  def max!(query, field, opts \\ []),
    do: Ash.max!(query, field, options(query_resource(query), opts))

  def run_action(resource, action, args, opts \\ []) do
    options = options(resource, opts)

    resource
    |> Ash.ActionInput.for_action(action, args, options)
    |> Ash.run_action(options)
    |> normalize_result()
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

  @doc false
  def normalize_result({:error, %module{} = subject}) when module in [Ash.Changeset, Ash.Query],
    do: normalize_result({:error, Ash.Error.to_error_class(subject)})

  def normalize_result({:error, %Ash.Error.Invalid{errors: errors} = invalid}) do
    case Enum.find_value(errors, fn
           %Ankole.Ash.DomainError{reason: reason} -> {:ok, reason}
           _other -> nil
         end) do
      {:ok, reason} -> {:error, reason}
      nil -> {:error, invalid}
    end
  end

  def normalize_result(other), do: other

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
