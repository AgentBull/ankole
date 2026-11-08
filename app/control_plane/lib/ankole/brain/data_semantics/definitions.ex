defmodule Ankole.Brain.DataSemantics.Definitions do
  @moduledoc """
  Validates the frontmatter of dataset, metric, and entity objects into the
  rows that `Ankole.Brain.DataSemantics` stores, and validates execution
  parameters against a metric revision.

  Base references are checked against the live Base schema: every field and
  table ID that a binding or an aggregate spec names must exist, and the
  stored rows snapshot each referenced field's type for drift detection.
  A metric revision also copies its binding's keys and field types and
  resolves a connector table's schema from the catalog cache, so drift
  detection for the revision reads only the revision itself.
  """
  require Ash.Query
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.DatasetBinding
  alias Ankole.Pod.Bases

  @cardinalities ~w(many_to_one one_to_one one_to_many many_to_many)
  @parameter_types ~w(string integer number boolean date datetime)
  @name ~r/^[a-z][a-z0-9_]{0,62}$/
  @namespace ~r/^[A-Za-z0-9][A-Za-z0-9_.:\/-]{0,199}$/
  # Link traversal depth for fields that an aggregate spec reaches through
  # link fields of the bound table.
  @link_depth 3

  ## Datasets

  @doc """
  Returns `{:ok, :draft}` for a dataset object without `source`, or the
  binding attributes and the page IDs of its join targets.
  """
  def dataset(meta, page_id) do
    case meta["source"] do
      nil ->
        {:ok, :draft}

      source ->
        with {:ok, grain} <- text(meta, "grain", :dataset),
             {:ok, bound} <- dataset_source(source),
             {:ok, primary} <- keys(meta, "primary_key"),
             {:ok, business} <- keys(meta, "business_key"),
             {:ok, entity_key} <- entity_key(meta["entity_key"]),
             {:ok, joins} <- joins(meta["joins_to"], page_id, bound),
             own = primary ++ business ++ entity_columns(entity_key) ++ join_from(joins),
             {:ok, field_types} <- dataset_field_types(bound, own, joins) do
          {:ok,
           Map.merge(bound.attrs, %{
             grain: grain,
             primary_key: primary,
             business_key: business,
             entity_key: entity_key,
             joins: Enum.map(joins, &Map.delete(&1, "target")),
             field_types: field_types
           }), Enum.map(joins, & &1["dataset_page_id"])}
        end
    end
  end

  defp dataset_source(%{"kind" => "base", "table_id" => id}) when is_binary(id) do
    case Bases.fetch_table(id) do
      {:ok, table} ->
        {:ok,
         %{
           kind: :base,
           table: table,
           attrs: %{
             source_kind: :base,
             base_page_id: table.page_id,
             base_table_id: table.id,
             connection_slug: nil,
             source_catalog: nil,
             source_schema: nil,
             source_table: nil
           }
         }}

      {:error, :not_found} ->
        dataset_error("source.table_id", "names no live Base table")
    end
  end

  defp dataset_source(%{"kind" => "connector", "connection" => slug, "table" => table} = source)
       when is_binary(slug) and is_binary(table) do
    with {:ok, slug} <- present(slug, "source.connection", :dataset),
         {:ok, table} <- present(table, "source.table", :dataset),
         {:ok, catalog} <- optional_text(source["catalog"], "source.catalog", :dataset),
         {:ok, schema} <- optional_text(source["schema"], "source.schema", :dataset) do
      {:ok,
       %{
         kind: :connector,
         attrs: %{
           source_kind: :connector,
           base_page_id: nil,
           base_table_id: nil,
           connection_slug: slug,
           source_catalog: catalog,
           source_schema: schema,
           source_table: table
         }
       }}
    end
  end

  defp dataset_source(_source),
    do:
      dataset_error(
        "source",
        "needs kind: base with table_id, or kind: connector with connection and table"
      )

  defp keys(meta, key) do
    case Map.get(meta, key, []) do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
          do: {:ok, list},
          else: dataset_error(key, "must list field IDs or column names")

      _ ->
        dataset_error(key, "must list field IDs or column names")
    end
  end

  defp entity_key(nil), do: {:ok, nil}

  defp entity_key(%{"key" => key, "entity_type" => type, "namespace" => namespace})
       when is_binary(key) and is_binary(type) and is_binary(namespace) do
    cond do
      not Regex.match?(@namespace, namespace) ->
        dataset_error(
          "entity_key.namespace",
          "must be an identifier namespace such as erp.supplier_id"
        )

      not Enum.any?(Ankole.Ash.read!(Ankole.Brain.Schemas.SchemaType), &(&1.name == type)) ->
        dataset_error("entity_key.entity_type", "names no installed Brain type")

      true ->
        {:ok, %{"key" => key, "entity_type" => type, "namespace" => namespace}}
    end
  end

  defp entity_key(_entity_key),
    do: dataset_error("entity_key", "needs key, entity_type, and namespace")

  defp entity_columns(nil), do: []
  defp entity_columns(%{"key" => key}), do: [key]

  defp joins(nil, _page_id, _bound), do: {:ok, []}

  defp joins(joins, page_id, bound) when is_list(joins) do
    collect(joins, fn join -> join(join, page_id, bound) end)
  end

  defp joins(_joins, _page_id, _bound), do: dataset_error("joins_to", "must be a list")

  defp join(
         %{"dataset" => reference, "keys" => [_ | _] = keys, "cardinality" => cardinality},
         page_id,
         bound
       )
       when is_binary(reference) and cardinality in @cardinalities do
    with {:ok, target_id, target} <- join_target(reference, page_id, bound),
         true <-
           Enum.all?(keys, fn
             %{"from" => from, "to" => to} -> is_binary(from) and is_binary(to)
             _ -> false
           end) do
      {:ok,
       %{
         "dataset_page_id" => target_id,
         "keys" => Enum.map(keys, &Map.take(&1, ["from", "to"])),
         "cardinality" => cardinality,
         "target" => target
       }}
    else
      false -> dataset_error("joins_to.keys", "must list from and to key pairs")
      error -> error
    end
  end

  defp join(_join, _page_id, _bound),
    do:
      dataset_error(
        "joins_to",
        "each join needs dataset, keys, and cardinality (#{Enum.join(@cardinalities, ", ")})"
      )

  defp join_target(reference, page_id, bound) do
    case Objects.resolve_slug(reference) do
      {:ok, %{id: ^page_id}} ->
        {:ok, page_id, bound}

      {:ok, %{id: id, deleted_at: nil}} ->
        case dataset_binding(id) do
          nil -> dataset_error("joins_to.dataset", "#{reference} has no dataset source")
          binding -> {:ok, id, bound_from_binding(binding)}
        end

      _ ->
        dataset_error("joins_to.dataset", "#{reference} is not a dataset object")
    end
  end

  defp bound_from_binding(%{source_kind: :base} = binding) do
    case Bases.fetch_table(binding.base_table_id) do
      {:ok, table} -> %{kind: :base, table: table}
      {:error, :not_found} -> %{kind: :base, table: nil}
    end
  end

  defp bound_from_binding(_binding), do: %{kind: :connector}

  defp join_from(joins),
    do: Enum.flat_map(joins, fn join -> Enum.map(join["keys"], & &1["from"]) end)

  # Records the type of every Base key field: this dataset's own keys and
  # the `to` keys of Base join targets.
  defp dataset_field_types(bound, own, joins) do
    targets =
      for join <- joins,
          join["target"].kind == :base,
          do: {join["target"].table, Enum.map(join["keys"], & &1["to"])}

    if(bound.kind == :base, do: [{bound.table, own} | targets], else: targets)
    |> Enum.reduce_while({:ok, %{}}, fn {table, ids}, {:ok, acc} ->
      case base_field_types(table, ids) do
        {:ok, types} -> {:cont, {:ok, deep_merge(acc, types)}}
        error -> {:halt, error}
      end
    end)
  end

  defp base_field_types(nil, _ids),
    do: dataset_error("joins_to.dataset", "binds a Base table that no longer exists")

  defp base_field_types(table, ids) do
    fields = Map.new(Bases.fields(table.id), &{&1.id, to_string(&1.type)})

    case Enum.reject(ids, &Map.has_key?(fields, &1)) do
      [] -> {:ok, %{table.id => Map.take(fields, ids)}}
      missing -> dataset_error("keys", "#{Enum.join(missing, ", ")} is not a field of the table")
    end
  end

  @doc "Returns the binding of one dataset object, or nil."
  def dataset_binding(page_id),
    do:
      DatasetBinding
      |> Ash.Query.filter(dataset_page_id == ^page_id)
      |> Ankole.Ash.read_one!()

  ## Metrics

  @doc """
  Returns `{:ok, :draft}` without `dataset`, `{:ok, :retired}` for
  `status: retired`, or the revision attributes and the dataset page ID.
  """
  def metric(meta) do
    cond do
      meta["status"] == "retired" ->
        {:ok, :retired}

      meta["status"] not in [nil, "published"] ->
        metric_error("status", "must be published or retired")

      is_nil(meta["dataset"]) ->
        {:ok, :draft}

      true ->
        with {:ok, dataset_id, binding} <- metric_dataset(meta["dataset"]),
             {:ok, grain} <- text(meta, "grain", :metric),
             {:ok, unit} <- text(meta, "unit", :metric),
             {:ok, numerator} <- text(meta, "numerator", :metric),
             {:ok, denominator} <- optional_text(meta["denominator"], "denominator", :metric),
             {:ok, time_field} <- optional_text(meta["time_field"], "time_field", :metric),
             {:ok, parameters} <- parameters(meta["parameters"]),
             {:ok, dimensions} <- dimensions(meta["addible_dimensions"], binding.source_kind),
             {:ok, executable} <- executable(binding, meta, parameters, dimensions, time_field) do
          {:ok,
           Map.merge(executable, %{
             dataset_binding_id: binding.id,
             source_kind: binding.source_kind,
             grain: grain,
             unit: unit,
             numerator: numerator,
             denominator: denominator,
             time_field: time_field,
             parameters: parameters,
             addible_dimensions: dimensions,
             status: :published
           }), dataset_id}
        end
    end
  end

  defp metric_dataset(reference) when is_binary(reference) do
    with {:ok, %{id: id, deleted_at: nil}} <- Objects.resolve_slug(reference),
         %DatasetBinding{} = binding <- dataset_binding(id) do
      {:ok, id, binding}
    else
      _ -> metric_error("dataset", "#{reference} is not a dataset object with a source")
    end
  end

  defp metric_dataset(_reference), do: metric_error("dataset", "must be a dataset path or ID")

  defp parameters(nil), do: {:ok, []}

  defp parameters(list) when is_list(list) do
    with {:ok, parameters} <- collect(list, &parameter/1) do
      names = Enum.map(parameters, & &1["name"])

      if length(Enum.uniq(names)) == length(names),
        do: {:ok, parameters},
        else: metric_error("parameters", "parameter names must be unique")
    end
  end

  defp parameters(_list), do: metric_error("parameters", "must be a list")

  defp parameter(%{"name" => name, "type" => type} = parameter)
       when is_binary(name) and type in @parameter_types do
    required = Map.get(parameter, "required", false)
    enum = parameter["enum"]

    cond do
      not Regex.match?(@name, name) or name == "dimensions" ->
        metric_error("parameters.name", "#{name} must be a lowercase name other than dimensions")

      not is_boolean(required) ->
        metric_error("parameters.required", "#{name} required must be true or false")

      not (is_nil(enum) or
               (is_list(enum) and enum != [] and
                  Enum.all?(enum, &(cast(type, &1) == {:ok, &1})))) ->
        metric_error("parameters.enum", "#{name} enum must list #{type} values")

      not required and not Map.has_key?(parameter, "default") ->
        metric_error("parameters.default", "#{name} needs required: true or a default")

      Map.has_key?(parameter, "default") and
          not valid_value?(parameter_spec(name, type, enum), parameter["default"]) ->
        metric_error("parameters.default", "#{name} default must be a valid #{type}")

      true ->
        {:ok,
         parameter
         |> Map.take(["name", "type", "required", "default", "enum", "description"])
         |> Map.put("required", required)}
    end
  end

  defp parameter(_parameter),
    do:
      metric_error(
        "parameters",
        "each parameter needs a name and a type (#{Enum.join(@parameter_types, ", ")})"
      )

  defp parameter_spec(name, type, enum), do: %{"name" => name, "type" => type, "enum" => enum}

  defp dimensions(nil, _kind), do: {:ok, []}

  defp dimensions(list, kind) when is_list(list) do
    with {:ok, dimensions} <- collect(list, &dimension(&1, kind)) do
      names = Enum.map(dimensions, & &1["name"])

      if length(Enum.uniq(names)) == length(names),
        do: {:ok, dimensions},
        else: metric_error("addible_dimensions", "dimension names must be unique")
    end
  end

  defp dimensions(_list, _kind), do: metric_error("addible_dimensions", "must be a list")

  defp dimension(%{"name" => name, "field_id" => field} = dimension, :base)
       when is_binary(name) and is_binary(field) do
    with :ok <- dimension_name(name),
         :ok <-
           if(is_nil(dimension["bucket"]) or is_binary(dimension["bucket"]),
             do: :ok,
             else: metric_error("addible_dimensions.bucket", "#{name} bucket must be text")
           ) do
      {:ok,
       dimension |> Map.take(["name", "field_id", "bucket"]) |> Map.reject(&is_nil(elem(&1, 1)))}
    end
  end

  defp dimension(%{"name" => name, "column" => column}, :connector)
       when is_binary(name) and is_binary(column) do
    with :ok <- dimension_name(name), do: {:ok, %{"name" => name, "column" => column}}
  end

  defp dimension(_dimension, :base),
    do: metric_error("addible_dimensions", "each Base dimension needs name and field_id")

  defp dimension(_dimension, :connector),
    do: metric_error("addible_dimensions", "each connector dimension needs name and column")

  defp dimension_name(name) do
    if Regex.match?(@name, name),
      do: :ok,
      else: metric_error("addible_dimensions.name", "#{name} must be a lowercase name")
  end

  defp executable(%{source_kind: :base} = binding, meta, parameters, dimensions, time_field) do
    with {:ok, spec} <- base_spec(meta["spec"]),
         :ok <- placeholders(spec, parameters),
         {:ok, table} <- bound_table(binding),
         refs = spec_references(spec),
         field_ids =
           Enum.uniq(
             refs.fields ++
               refs.links ++ Enum.map(dimensions, & &1["field_id"]) ++ List.wrap(time_field)
           ),
         {:ok, field_types} <- spec_field_types(table, refs.tables, field_ids, refs.links) do
      {:ok,
       %{
         source: %{"base_page_id" => table.page_id, "table_id" => table.id},
         spec: spec,
         field_types: deep_merge(binding.field_types, field_types),
         source_columns: []
       }}
    end
  end

  defp executable(%{source_kind: :connector} = binding, meta, _parameters, dimensions, time) do
    with {:ok, sql} <- text(meta, "sql", :metric),
         {:ok, columns} <- columns(meta["columns"]),
         {:ok, schema} <- connector_schema(binding) do
      keys =
        binding.primary_key ++
          binding.business_key ++
          entity_columns(binding.entity_key) ++
          Enum.flat_map(binding.joins, fn join -> Enum.map(join["keys"], & &1["from"]) end)

      {:ok,
       %{
         source: %{
           "connection" => binding.connection_slug,
           "catalog" => binding.source_catalog,
           "schema" => schema,
           "table" => binding.source_table
         },
         spec: %{"sql" => sql},
         field_types: %{},
         source_columns:
           Enum.uniq(columns ++ Enum.map(dimensions, & &1["column"]) ++ List.wrap(time) ++ keys)
       }}
    end
  end

  # A catalog refresh reports missing tables under their actual schema, so the
  # revision stores the schema that the connection's catalog cache resolves.
  defp connector_schema(binding) do
    slug = binding.connection_slug
    table = binding.source_table

    with {:ok, config} <- Ankole.Connectors.get_auth_config(slug),
         {:ok, %{"schema" => schema}} <-
           Ankole.Connectors.describe_database_table(config, binding.source_schema, table) do
      {:ok, if(schema == "", do: nil, else: schema)}
    else
      {:error, :connection_required} ->
        metric_error("dataset", "connection #{slug} does not exist")

      {:error, :table_not_found} ->
        metric_error(
          "dataset",
          "#{table} is not in the cached catalog of connection #{slug}; refresh the connection's catalog, then save again"
        )

      {:error, %{code: "table_ambiguous", schemas: schemas}} ->
        metric_error(
          "dataset",
          "#{table} exists in schemas #{Enum.join(schemas, ", ")} of connection #{slug}; set source.schema on the dataset"
        )

      error ->
        error
    end
  end

  defp base_spec(%{"metrics" => [_ | _]} = spec), do: {:ok, spec}

  defp base_spec(_spec),
    do: metric_error("spec", "must be a Base aggregate spec with a non-empty metrics list")

  defp bound_table(binding) do
    case Bases.fetch_table(binding.base_table_id) do
      {:ok, table} -> {:ok, table}
      {:error, :not_found} -> metric_error("dataset", "binds a Base table that no longer exists")
    end
  end

  defp columns(nil), do: {:ok, []}

  defp columns(list) when is_list(list) do
    if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, list},
      else: metric_error("columns", "must list source column names")
  end

  defp columns(_list), do: metric_error("columns", "must list source column names")

  # Every `{"$param": name}` placeholder names a declared parameter.
  defp placeholders(spec, parameters) do
    declared = MapSet.new(parameters, & &1["name"])

    case Enum.reject(placeholder_names(spec), &MapSet.member?(declared, &1)) do
      [] -> :ok
      [name | _] -> metric_error("spec", "placeholder #{name} names no declared parameter")
    end
  end

  defp placeholder_names(%{"$param" => name}), do: [name]

  defp placeholder_names(map) when is_map(map),
    do: Enum.flat_map(Map.values(map), &placeholder_names/1)

  defp placeholder_names(list) when is_list(list), do: Enum.flat_map(list, &placeholder_names/1)
  defp placeholder_names(_value), do: []

  # Collects field, link-path, and table IDs wherever the aggregate spec names
  # them, so specs that follow link paths are checked the same way as flat specs.
  defp spec_references(spec), do: references(spec, %{fields: [], links: [], tables: []})

  defp references(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn
      {"field_id", id}, acc when is_binary(id) ->
        %{acc | fields: [id | acc.fields]}

      {"field_ids", ids}, acc when is_list(ids) ->
        %{acc | fields: Enum.filter(ids, &is_binary/1) ++ acc.fields}

      {"table_id", id}, acc when is_binary(id) ->
        %{acc | tables: [id | acc.tables]}

      {"path", ids}, acc when is_list(ids) ->
        %{acc | links: Enum.filter(ids, &is_binary/1) ++ acc.links}

      {_key, value}, acc ->
        references(value, acc)
    end)
  end

  defp references(list, acc) when is_list(list), do: Enum.reduce(list, acc, &references/2)
  defp references(_value, acc), do: acc

  # Path link fields record their own type, and each table a path reaches
  # records an entry, so deleting a link or a traversed table is drift.
  defp spec_field_types(table, table_ids, field_ids, links) do
    with {:ok, tables} <- spec_tables(table, Enum.uniq(table_ids)) do
      fields = reachable_fields(tables, [table.id], @link_depth)
      missing = Enum.reject(field_ids, &Map.has_key?(fields, &1))

      not_link =
        Enum.find(links, &match?({_table, type, _target} when type != "link", fields[&1]))

      cond do
        missing != [] ->
          metric_error(
            "spec",
            "#{Enum.join(missing, ", ")} names no field reachable from the dataset table"
          )

        not_link ->
          metric_error("spec", "path entry #{not_link} is not a link field")

        true ->
          types =
            Enum.reduce(field_ids, %{}, fn id, acc ->
              {table_id, type, _target} = Map.fetch!(fields, id)
              Map.update(acc, table_id, %{id => type}, &Map.put(&1, id, type))
            end)

          {:ok,
           for(id <- links, target = elem(fields[id], 2), is_binary(target), do: target)
           |> Enum.reduce(types, &Map.put_new(&2, &1, %{}))}
      end
    end
  end

  defp spec_tables(table, ids) do
    collect(ids -- [table.id], fn id ->
      case Bases.fetch_table(id) do
        {:ok, %{page_id: page_id}} when page_id == table.page_id -> {:ok, id}
        _ -> metric_error("spec", "table #{id} is not a live table of the dataset's Base")
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, [table.id | ids]}
      error -> error
    end
  end

  # Fields of the given tables and of tables reached through their link
  # fields, keyed by field ID with their table ID, type, and link target.
  defp reachable_fields(tables, _seen, 0), do: fields_of(tables)

  defp reachable_fields(tables, seen, depth) do
    fields = Enum.flat_map(tables, &Bases.fields/1)

    linked =
      fields
      |> Enum.filter(&(&1.type == :link and is_binary(&1.config["table_id"])))
      |> Enum.map(& &1.config["table_id"])
      |> Enum.uniq()
      |> Enum.reject(&(&1 in seen or &1 in tables))
      |> Enum.filter(&match?({:ok, _}, Bases.fetch_table(&1)))

    own = Map.new(fields, &field_entry/1)

    if linked == [],
      do: own,
      else: Map.merge(reachable_fields(linked, seen ++ tables, depth - 1), own)
  end

  defp fields_of(tables), do: tables |> Enum.flat_map(&Bases.fields/1) |> Map.new(&field_entry/1)

  defp field_entry(field),
    do:
      {field.id,
       {field.table_id, to_string(field.type), field.type == :link && field.config["table_id"]}}

  ## Execution parameters

  @doc """
  Checks caller parameters against a revision's typed parameter schema and
  addible dimensions. Returns the parameter values with defaults applied and
  the requested dimensions.
  """
  def execution_params(revision, params) when is_map(params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)
    {requested, values} = Map.pop(params, "dimensions", [])

    with {:ok, dimensions} <- requested_dimensions(revision, requested),
         :ok <- known_params(revision, values),
         {:ok, values} <- collect_values(revision.parameters, values) do
      {:ok, values, dimensions}
    end
  end

  def execution_params(_revision, _params),
    do: {:error, {:invalid_metric_params, %{message: "params must be an object"}}}

  defp requested_dimensions(revision, requested) when is_list(requested) do
    addible = Map.new(revision.addible_dimensions, &{&1["name"], &1})

    case Enum.find(requested, &(not Map.has_key?(addible, &1))) do
      nil ->
        {:ok, requested |> Enum.uniq() |> Enum.map(&Map.fetch!(addible, &1))}

      name ->
        {:error,
         {:dimension_not_addible,
          %{dimension: name, addible: addible |> Map.keys() |> Enum.sort()}}}
    end
  end

  defp requested_dimensions(_revision, _requested),
    do: {:error, {:invalid_metric_params, %{param: "dimensions", message: "must be a list"}}}

  defp known_params(revision, values) do
    declared = MapSet.new(revision.parameters, & &1["name"])

    case Enum.reject(Map.keys(values), &MapSet.member?(declared, &1)) do
      [] ->
        :ok

      [name | _] ->
        {:error, {:invalid_metric_params, %{param: name, message: "is not a parameter"}}}
    end
  end

  defp collect_values(parameters, values) do
    Enum.reduce_while(parameters, {:ok, %{}}, fn parameter, {:ok, acc} ->
      name = parameter["name"]

      case Map.fetch(values, name) do
        {:ok, value} ->
          if valid_value?(parameter, value),
            do: {:cont, {:ok, Map.put(acc, name, value)}},
            else: {:halt, invalid_param(name, "must be a valid #{parameter["type"]}")}

        :error ->
          if parameter["required"],
            do: {:halt, invalid_param(name, "is required")},
            else: {:cont, {:ok, Map.put(acc, name, parameter["default"])}}
      end
    end)
  end

  defp invalid_param(name, message),
    do: {:error, {:invalid_metric_params, %{param: name, message: message}}}

  defp valid_value?(parameter, value) do
    cast(parameter["type"], value) == {:ok, value} and
      (is_nil(parameter["enum"]) or value in parameter["enum"])
  end

  defp cast("string", value) when is_binary(value), do: {:ok, value}
  defp cast("integer", value) when is_integer(value), do: {:ok, value}
  defp cast("number", value) when is_number(value), do: {:ok, value}
  defp cast("boolean", value) when is_boolean(value), do: {:ok, value}

  defp cast("date", value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> {:ok, value}
      _ -> :error
    end
  end

  defp cast("datetime", value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> {:ok, value}
      _ -> :error
    end
  end

  defp cast(_type, _value), do: :error

  @doc "Replaces every `{\"$param\": name}` placeholder with its value."
  def substitute(%{"$param" => name}, values), do: Map.fetch!(values, name)

  def substitute(map, values) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, substitute(v, values)} end)

  def substitute(list, values) when is_list(list), do: Enum.map(list, &substitute(&1, values))
  def substitute(value, _values), do: value

  ## Entity identifiers

  @doc "Returns the `{namespace, value}` pairs of an `identifiers` map."
  def identifiers(nil), do: {:ok, []}

  def identifiers(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {namespace, values} ->
      Enum.map(List.wrap(values), &{namespace, &1})
    end)
    |> collect(fn {namespace, value} ->
      value = if is_integer(value), do: Integer.to_string(value), else: value

      cond do
        not (is_binary(namespace) and Regex.match?(@namespace, namespace)) ->
          identifiers_error("#{namespace} must be a namespace such as erp.supplier_id")

        not is_binary(value) or String.trim(value) == "" or String.length(value) > 500 ->
          identifiers_error("#{namespace} values must be non-blank text or integers")

        true ->
          {:ok, {namespace, String.trim(value)}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.uniq(pairs)}
      error -> error
    end
  end

  def identifiers(_map), do: identifiers_error("must map namespaces to values")

  ## Shared helpers

  defp text(meta, key, kind) do
    case meta[key] do
      value when is_binary(value) -> present(value, key, kind)
      _ -> error(kind, key, "is required text")
    end
  end

  defp present(value, key, kind) do
    if String.trim(value) == "", do: error(kind, key, "must not be blank"), else: {:ok, value}
  end

  defp optional_text(nil, _key, _kind), do: {:ok, nil}
  defp optional_text(value, key, kind) when is_binary(value), do: present(value, key, kind)
  defp optional_text(_value, key, kind), do: error(kind, key, "must be text")

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp deep_merge(left, right), do: Map.merge(left, right, fn _key, a, b -> Map.merge(a, b) end)

  defp dataset_error(key, message), do: error(:dataset, key, message)
  defp metric_error(key, message), do: error(:metric, key, message)

  defp identifiers_error(message),
    do: {:error, {:invalid_entity_identifiers, %{key: "identifiers", message: message}}}

  defp error(:dataset, key, message),
    do: {:error, {:invalid_dataset_definition, %{key: key, message: message}}}

  defp error(:metric, key, message),
    do: {:error, {:invalid_metric_definition, %{key: key, message: message}}}
end
