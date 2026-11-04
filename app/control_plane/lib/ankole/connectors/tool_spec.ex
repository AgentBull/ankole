defmodule Ankole.Connectors.ToolSpec do
  @moduledoc "The versioned contract shared by the MCP gateway, Skills, and Applet toolkit types."

  @enforce_keys [:toolkit, :name, :description, :input_schema, :output_schema, :operation]
  defstruct [
    :toolkit,
    :name,
    :description,
    :input_schema,
    :output_schema,
    :input_validator,
    :output_validator,
    :operation,
    annotations: %{},
    subject_policy: :any_principal,
    upstream_auth: :app_token,
    scopes: []
  ]

  @type t :: %__MODULE__{}

  def compile(%__MODULE__{} = tool) do
    %{
      tool
      | input_validator: Ankole.Sessions.ToolArguments.resolve(tool.input_schema),
        output_validator: Ankole.Sessions.ToolArguments.resolve(tool.output_schema)
    }
  end

  def public(%__MODULE__{} = tool) do
    %{
      "name" => tool.name,
      "description" => tool.description,
      "inputSchema" => tool.input_schema,
      "outputSchema" => public_output_schema(tool),
      "annotations" => tool.annotations
    }
  end

  def public_output_schema(%__MODULE__{output_schema: schema}), do: wire_schema(schema)
  def public_output_schema(schema) when is_map(schema), do: wire_schema(schema)

  defp wire_schema(%{"type" => "integer", "format" => format} = schema)
       when format in ["int64", "uint64"],
       do:
         schema
         |> Map.put("type", "string")
         |> Map.delete("format")
         |> Map.put("pattern", "^-?[0-9]+$")

  defp wire_schema(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, wire_schema(item)} end)

  defp wire_schema(value) when is_list(value), do: Enum.map(value, &wire_schema/1)
  defp wire_schema(value), do: value

  def validate_input(%__MODULE__{} = tool, value),
    do: Ankole.Sessions.ToolArguments.validate(tool.input_validator || tool.input_schema, value)

  def validate_output(%__MODULE__{} = tool, value),
    do: Ankole.Sessions.ToolArguments.validate(tool.output_validator || tool.output_schema, value)

  def retry_safe?(%__MODULE__{annotations: annotations}),
    do: annotations["readOnlyHint"] == true or annotations["idempotentHint"] == true

  def annotations(read_only, idempotent \\ false, destructive \\ false) do
    %{
      "readOnlyHint" => read_only,
      "idempotentHint" => read_only or idempotent,
      "destructiveHint" => destructive,
      "openWorldHint" => true
    }
  end
end
