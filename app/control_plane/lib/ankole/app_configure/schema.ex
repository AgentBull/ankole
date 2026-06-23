defmodule Ankole.AppConfigure.Schema do
  @moduledoc """
  Small schema validators for AppConfigure JSON values.

  A schema returns `{:ok, value}` after validation. Returning a normalized value
  lets callers keep validation and light parsing at the definition boundary
  instead of scattering casts through runtime call sites.
  """

  @enforce_keys [:validator]
  defstruct [:validator]

  @type reason :: term()
  @type validation_result :: {:ok, term()} | {:error, reason()}
  @type validator :: (term() -> validation_result())
  @type t :: %__MODULE__{validator: validator()}

  @doc """
  Wraps a custom validator in an AppConfigure schema.
  """
  @spec new(validator()) :: t()
  def new(validator) when is_function(validator, 1), do: %__MODULE__{validator: validator}

  @doc """
  Runs a schema or raw validator against one value.
  """
  @spec validate(t() | validator(), term()) :: validation_result()
  def validate(%__MODULE__{validator: validator}, value), do: validator.(value)
  def validate(validator, value) when is_function(validator, 1), do: validator.(value)

  @doc """
  Accepts any value that can be stored as JSON and PostgreSQL `jsonb`.
  """
  @spec json_value() :: t()
  def json_value do
    new(fn value ->
      case json_value?(value) do
        true -> {:ok, value}
        false -> {:error, :not_json_value}
      end
    end)
  end

  @doc """
  Accepts JSON objects with string keys.

  Structs and atom-key maps are rejected because they are Elixir terms, not plain
  JSON objects.
  """
  @spec object() :: t()
  def object do
    new(fn
      value when is_map(value) ->
        case json_value?(value) do
          true -> {:ok, value}
          false -> {:error, :not_json_object}
        end

      _value ->
        {:error, :not_json_object}
    end)
  end

  @doc """
  Accepts JSON strings.
  """
  @spec string() :: t()
  def string do
    new(fn
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, :not_string}
    end)
  end

  @doc """
  Accepts non-empty JSON strings.
  """
  @spec non_empty_string() :: t()
  def non_empty_string do
    new(fn
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :not_non_empty_string}
    end)
  end

  @doc """
  Accepts JSON booleans.
  """
  @spec boolean() :: t()
  def boolean do
    new(fn
      value when is_boolean(value) -> {:ok, value}
      _value -> {:error, :not_boolean}
    end)
  end

  @doc """
  Accepts JSON numbers represented as Elixir integers.
  """
  @spec integer() :: t()
  def integer do
    new(fn
      value when is_integer(value) -> {:ok, value}
      _value -> {:error, :not_integer}
    end)
  end

  @doc """
  Accepts JSON numbers represented as Elixir numbers.
  """
  @spec number() :: t()
  def number do
    new(fn
      value when is_number(value) -> {:ok, value}
      _value -> {:error, :not_number}
    end)
  end

  @doc """
  Accepts one of a fixed list of JSON-compatible values.
  """
  @spec enum([term()]) :: t()
  def enum(values) when is_list(values) do
    Enum.each(values, &ensure_json_value!/1)

    new(fn value ->
      case value in values do
        true -> {:ok, value}
        false -> {:error, {:not_in_enum, values}}
      end
    end)
  end

  @doc """
  Accepts arrays whose items all satisfy the nested schema.
  """
  @spec array(t() | validator()) :: t()
  def array(item_schema) do
    new(fn
      values when is_list(values) ->
        validate_array(values, item_schema)

      _value ->
        {:error, :not_array}
    end)
  end

  @doc """
  Checks whether a value is safe to persist through the AppConfigure JSON boundary.
  """
  @spec ensure_json_value(term()) :: validation_result()
  def ensure_json_value(value) do
    case json_value?(value) do
      true -> {:ok, value}
      false -> {:error, :not_json_value}
    end
  end

  @doc """
  Returns whether a value is JSON-compatible without allocating an error tuple.
  """
  @spec json_value?(term()) :: boolean()
  def json_value?(nil), do: true
  def json_value?(value) when is_boolean(value), do: true
  def json_value?(value) when is_binary(value), do: true
  def json_value?(value) when is_integer(value), do: true
  def json_value?(value) when is_float(value), do: true
  def json_value?(values) when is_list(values), do: Enum.all?(values, &json_value?/1)

  # Maps are accepted only when they look like JSON objects. This keeps accidental
  # atom-key option maps from becoming durable runtime configuration.
  def json_value?(value) when is_map(value) do
    case is_struct(value) do
      true -> false
      false -> Enum.all?(value, &json_object_entry?/1)
    end
  end

  def json_value?(_value), do: false

  defp validate_array(values, item_schema) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case validate(item_schema, value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, {:invalid_array_item, reason}}}
      end
    end)
    |> case do
      {:ok, parsed_values} -> {:ok, Enum.reverse(parsed_values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp json_object_entry?({key, value}) when is_binary(key), do: json_value?(value)
  defp json_object_entry?(_entry), do: false

  defp ensure_json_value!(value) do
    case ensure_json_value(value) do
      {:ok, _value} ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "enum value is not JSON-compatible: #{inspect(reason)}"
    end
  end
end
