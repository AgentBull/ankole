defmodule Ankole.Sessions.ToolArguments do
  @moduledoc "Bounds and parses complete JSON tool arguments before execution."

  alias Ankole.JSON
  @argument_limit 256 * 1024

  def parse(text) when is_binary(text) and byte_size(text) > @argument_limit,
    do: {:error, "tool arguments exceed the #{@argument_limit}-byte limit"}

  def parse(text) when is_binary(text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, "tool arguments must be valid JSON: #{inspect(reason)}"}
    end
  end

  def resolve(schema) do
    ExJsonSchema.Schema.resolve(
      Map.put(schema, "$schema", "http://json-schema.org/draft-07/schema#")
    )
  end

  @doc """
  Validates arguments that a model wrote. A model often writes `""` or `null`
  for an optional parameter that it means to omit, so such a value counts as
  omitted when the schema rejects it.
  """
  def validate(%ExJsonSchema.Schema.Root{} = schema, value) do
    case ExJsonSchema.Validator.validate(schema, value) do
      :ok ->
        {:ok, value}

      {:error, errors} ->
        case rejected_blanks(schema, value, errors) do
          [] -> {:error, describe(errors)}
          keys -> validate(schema, Map.drop(value, keys))
        end
    end
  end

  def validate(schema, value), do: validate(resolve(schema), value)

  @doc "Validates a value that must match its schema as it is, such as a tool's declared output."
  def validate_exact(%ExJsonSchema.Schema.Root{} = schema, value) do
    case ExJsonSchema.Validator.validate(schema, value) do
      :ok -> {:ok, value}
      {:error, errors} -> {:error, describe(errors)}
    end
  end

  def validate_exact(schema, value), do: validate_exact(resolve(schema), value)

  defp describe(errors),
    do: Enum.map_join(errors, "; ", fn {message, path} -> "#{path}: #{message}" end)

  defp rejected_blanks(%{schema: root}, value, errors) when is_map(value) do
    required = root["required"] || []

    for {_message, "#/" <> key} <- errors,
        key not in required,
        Map.get(value, key, :absent) in ["", nil],
        uniq: true,
        do: key
  end

  defp rejected_blanks(_schema, _value, _errors), do: []
end
