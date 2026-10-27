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

  def validate(schema, value) do
    schema =
      ExJsonSchema.Schema.resolve(
        Map.put(schema, "$schema", "http://json-schema.org/draft-07/schema#")
      )

    case ExJsonSchema.Validator.validate(schema, value) do
      :ok ->
        {:ok, value}

      {:error, errors} ->
        {:error, Enum.map_join(errors, "; ", fn {message, path} -> "#{path}: #{message}" end)}
    end
  end
end
