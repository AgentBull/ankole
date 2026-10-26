defmodule Ankole.Workflow.ResultSchema do
  @moduledoc """
  Validates the closed Workflow result-schema subset and submitted JSON values.

  Result validation has two ordered guards. The raw guard runs first because
  OpenApiSpex can coerce JSON values; it preserves exact declared types and
  enforces numeric constraints that Cast does not preserve. OpenApiSpex Cast
  then enforces structural constraints such as required properties, closed
  objects, string patterns and lengths, and array lengths. Validation returns
  the original value, never the cast value.
  """

  alias OpenApiSpex.Cast
  alias OpenApiSpex.Cast.Error, as: CastError
  alias OpenApiSpex.Schema

  @schema_max_depth 16
  @schema_max_properties 128
  @schema_types %{
    "object" => :object,
    "array" => :array,
    "string" => :string,
    "number" => :number,
    "integer" => :integer,
    "boolean" => :boolean
  }
  @common_schema_keys ~w(type title description enum)
  @schema_keys %{
    "object" => @common_schema_keys ++ ~w(properties required additionalProperties),
    "array" => @common_schema_keys ++ ~w(items minItems maxItems),
    "string" => @common_schema_keys ++ ~w(minLength maxLength pattern),
    "number" => @common_schema_keys ++ ~w(minimum maximum),
    "integer" => @common_schema_keys ++ ~w(minimum maximum multipleOf),
    "boolean" => @common_schema_keys
  }

  @spec validate_schema(term()) :: :ok | {:error, term()}
  def validate_schema(schema) do
    case schema_from_map(schema, 0) do
      {:ok, %Schema{}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec validate(term(), term()) :: {:ok, term()} | {:error, term()}
  def validate(schema, value) do
    with {:ok, openapi_schema} <- schema_from_map(schema, 0),
         :ok <- validate_raw_type(schema, value, []),
         {:ok, _casted} <- cast_safely(openapi_schema, value) do
      {:ok, value}
    end
  end

  defp schema_from_map(_schema, depth) when depth > @schema_max_depth,
    do: {:error, :workflow_schema_too_deep}

  defp schema_from_map(schema, depth) when is_map(schema) do
    with :ok <- ensure_string_keys(schema),
         {:ok, type} <- schema_type(Map.get(schema, "type")),
         :ok <- reject_unsupported_schema_keys(schema, type),
         :ok <- validate_annotations(schema),
         :ok <- validate_enum(Map.get(schema, "enum"), type),
         {:ok, typed_fields} <- typed_schema_fields(type, schema, depth) do
      {:ok,
       struct!(
         Schema,
         Map.merge(
           %{
             type: Map.fetch!(@schema_types, type),
             nullable: false,
             title: Map.get(schema, "title"),
             description: Map.get(schema, "description"),
             enum: nil
           },
           typed_fields
         )
       )}
    end
  rescue
    exception -> {:error, {:invalid_workflow_schema, Exception.message(exception)}}
  end

  defp schema_from_map(_schema, _depth), do: {:error, :invalid_workflow_schema}

  defp schema_type(type)
       when is_binary(type) and type in ~w(object array string number integer boolean),
       do: {:ok, type}

  defp schema_type(_type), do: {:error, :workflow_schema_type_required}

  defp reject_unsupported_schema_keys(schema, type) do
    unsupported = Map.keys(schema) -- Map.fetch!(@schema_keys, type)

    case unsupported do
      [] -> :ok
      keys -> {:error, {:unsupported_workflow_schema_keywords, Enum.sort(keys)}}
    end
  end

  defp validate_annotations(schema) do
    if Enum.all?(~w(title description), fn key ->
         is_nil(Map.get(schema, key)) or is_binary(Map.get(schema, key))
       end) do
      :ok
    else
      {:error, :invalid_workflow_schema_annotation}
    end
  end

  defp validate_enum(nil, _type), do: :ok

  defp validate_enum(values, type) when is_list(values) and values != [] do
    if Enum.all?(values, &raw_type?(&1, type)),
      do: :ok,
      else: {:error, :invalid_workflow_schema_enum}
  end

  defp validate_enum(_values, _type), do: {:error, :invalid_workflow_schema_enum}

  defp typed_schema_fields("object", schema, depth) do
    properties = Map.get(schema, "properties")
    required = Map.get(schema, "required")
    additional = Map.get(schema, "additionalProperties")

    with true <- is_map(properties) || {:error, :invalid_workflow_schema_properties},
         :ok <- ensure_string_keys(properties),
         true <-
           map_size(properties) <= @schema_max_properties ||
             {:error, :workflow_schema_too_many_properties},
         true <-
           (is_list(required) and Enum.all?(required, &is_binary/1)) ||
             {:error, :invalid_workflow_schema_required},
         true <- Enum.uniq(required) == required || {:error, :invalid_workflow_schema_required},
         true <-
           Enum.sort(required) == Enum.sort(Map.keys(properties)) ||
             {:error, :invalid_workflow_schema_required},
         true <-
           additional == false || {:error, :invalid_workflow_schema_additional_properties},
         {:ok, translated} <- translate_properties(properties, depth + 1) do
      {:ok,
       %{
         properties: translated,
         required: required,
         additionalProperties: false
       }}
    end
  end

  defp typed_schema_fields("array", schema, depth) do
    with items when is_map(items) <- Map.get(schema, "items"),
         {:ok, items} <- schema_from_map(items, depth + 1),
         {:ok, min_items} <- optional_nonnegative_integer(schema, "minItems"),
         {:ok, max_items} <- optional_nonnegative_integer(schema, "maxItems"),
         :ok <- validate_bounds(min_items, max_items) do
      {:ok, %{items: items, minItems: min_items, maxItems: max_items}}
    else
      nil -> {:error, :workflow_schema_array_items_required}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_workflow_schema_array_items}
    end
  end

  defp typed_schema_fields("string", schema, _depth) do
    with {:ok, min_length} <- optional_nonnegative_integer(schema, "minLength"),
         {:ok, max_length} <- optional_nonnegative_integer(schema, "maxLength"),
         :ok <- validate_bounds(min_length, max_length),
         {:ok, pattern} <- optional_pattern(schema) do
      {:ok, %{minLength: min_length, maxLength: max_length, pattern: pattern}}
    end
  end

  defp typed_schema_fields("number", schema, _depth) do
    with {:ok, minimum} <- optional_number(schema, "minimum"),
         {:ok, maximum} <- optional_number(schema, "maximum"),
         :ok <- validate_bounds(minimum, maximum) do
      {:ok, %{minimum: minimum, maximum: maximum}}
    end
  end

  defp typed_schema_fields("integer", schema, _depth) do
    with {:ok, minimum} <- optional_number(schema, "minimum"),
         {:ok, maximum} <- optional_number(schema, "maximum"),
         :ok <- validate_bounds(minimum, maximum),
         {:ok, multiple_of} <- optional_positive_integer(schema, "multipleOf") do
      {:ok, %{minimum: minimum, maximum: maximum, multipleOf: multiple_of}}
    end
  end

  defp typed_schema_fields("boolean", _schema, _depth), do: {:ok, %{}}

  defp translate_properties(properties, depth) do
    Enum.reduce_while(properties, {:ok, %{}}, fn {name, schema}, {:ok, translated} ->
      case schema_from_map(schema, depth) do
        {:ok, property_schema} -> {:cont, {:ok, Map.put(translated, name, property_schema)}}
        {:error, reason} -> {:halt, {:error, {:invalid_workflow_schema_property, name, reason}}}
      end
    end)
  end

  defp validate_raw_type(schema, value, path) do
    type = Map.get(schema, "type")

    cond do
      not raw_type?(value, type) ->
        {:error, {:workflow_result_type_mismatch, path, type}}

      is_list(Map.get(schema, "enum")) and
          not Enum.any?(Map.get(schema, "enum"), &(&1 == value)) ->
        {:error, {:workflow_result_enum_mismatch, path}}

      type in ["number", "integer"] ->
        validate_raw_number(schema, value, path)

      type == "object" ->
        validate_raw_object(schema, value, path)

      type == "array" ->
        schema
        |> Map.fetch!("items")
        |> then(fn item_schema ->
          value
          |> Enum.with_index()
          |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
            case validate_raw_type(item_schema, item, path ++ [index]) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        end)

      true ->
        :ok
    end
  end

  defp validate_raw_object(schema, value, path) do
    properties = Map.get(schema, "properties", %{})

    with :ok <- ensure_string_keys(value) do
      Enum.reduce_while(properties, :ok, fn {name, property_schema}, :ok ->
        case Map.fetch(value, name) do
          {:ok, property_value} ->
            case validate_raw_type(property_schema, property_value, path ++ [name]) do
              :ok -> {:cont, :ok}
              {:error, _reason} = error -> {:halt, error}
            end

          :error ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp validate_raw_number(schema, value, path) do
    minimum = Map.get(schema, "minimum")
    maximum = Map.get(schema, "maximum")
    multiple_of = Map.get(schema, "multipleOf")

    cond do
      is_number(minimum) and value < minimum ->
        {:error, {:workflow_result_minimum, path, minimum}}

      is_number(maximum) and value > maximum ->
        {:error, {:workflow_result_maximum, path, maximum}}

      is_number(multiple_of) and not multiple_of?(value, multiple_of) ->
        {:error, {:workflow_result_multiple_of, path, multiple_of}}

      true ->
        :ok
    end
  end

  defp multiple_of?(value, multiple), do: Integer.mod(value, multiple) == 0

  defp raw_type?(value, "object"), do: is_map(value) and not is_struct(value)
  defp raw_type?(value, "array"), do: is_list(value)
  defp raw_type?(value, "string"), do: is_binary(value)
  defp raw_type?(value, "number"), do: is_integer(value) or is_float(value)
  defp raw_type?(value, "integer"), do: is_integer(value)
  defp raw_type?(value, "boolean"), do: is_boolean(value)
  defp raw_type?(_value, _type), do: false

  defp cast_safely(schema, value) do
    case Cast.cast(schema, value) do
      {:ok, casted} ->
        {:ok, casted}

      {:error, errors} ->
        {:error, {:workflow_result_schema_mismatch, cast_error_messages(errors)}}
    end
  rescue
    exception -> {:error, {:workflow_result_schema_cast_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:workflow_result_schema_cast_failed, {kind, reason}}}
  end

  defp cast_error_messages(errors) do
    Enum.map(errors, &CastError.message_with_path/1)
  end

  defp ensure_string_keys(map) do
    if Enum.all?(Map.keys(map), &is_binary/1),
      do: :ok,
      else: {:error, :workflow_schema_keys_must_be_strings}
  end

  defp optional_nonnegative_integer(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, {:invalid_workflow_schema_bound, key}}
    end
  end

  defp optional_number(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_integer(value) or is_float(value) -> {:ok, value}
      _value -> {:error, {:invalid_workflow_schema_bound, key}}
    end
  end

  defp optional_positive_integer(map, key) do
    case optional_nonnegative_integer(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_workflow_schema_bound, key}}
      {:error, _reason} = error -> error
    end
  end

  defp optional_pattern(map) do
    case Map.get(map, "pattern") do
      nil -> {:ok, nil}
      pattern when is_binary(pattern) -> Regex.compile(pattern)
      _value -> {:error, :invalid_workflow_schema_pattern}
    end
  end

  defp validate_bounds(nil, _maximum), do: :ok
  defp validate_bounds(_minimum, nil), do: :ok
  defp validate_bounds(minimum, maximum) when minimum <= maximum, do: :ok
  defp validate_bounds(_minimum, _maximum), do: {:error, :invalid_workflow_schema_bounds}
end
