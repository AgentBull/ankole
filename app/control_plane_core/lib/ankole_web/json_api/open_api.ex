defmodule AnkoleWeb.JSONAPI.OpenAPI do
  @moduledoc """
  Completes the OpenAPI document of a JSON:API router.

  AshJsonApi derives the paths and schemas from the `json_api` sections. This
  module sets the title, the version, and the Console session security scheme
  of `AnkoleWeb.APISpec`. `mix ankole.openapi.check` keeps the committed
  documents current.

  AshJsonApi writes an optional field as `anyOf: [schema, {type: "null"}]`.
  The document is OpenAPI 3.0, which has no `null` type, so a generated client
  types the field as `unknown`. This module writes the field as the schema with
  `nullable: true`. AshJsonApi also writes no type for a `:utc_datetime_usec`
  attribute; this module gives it the `date-time` string type.
  """

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Info

  @version "2026-10-23"

  @doc "The `modify_open_api` function of a JSON:API router."
  def modify(spec, _conn, opts, scope) do
    %{
      spec
      | info: %Info{title: title(scope), version: @version},
        components: %{
          spec.components
          | securitySchemes: %{"consoleSession" => AnkoleWeb.APISpec.console_session()}
        },
        security: [%{"consoleSession" => []}]
    }
    |> nullable()
    |> datetimes(Keyword.fetch!(opts, :domains))
  end

  defp datetimes(spec, domains) do
    schemas =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          AshJsonApi.Resource in Spark.extensions(resource),
          attribute <- Ash.Resource.Info.public_attributes(resource),
          attribute.type == Ash.Type.UtcDatetimeUsec,
          reduce: spec.components.schemas do
        schemas ->
          type = AshJsonApi.Resource.Info.type(resource)
          key = AshJsonApi.Resource.Info.field_to_json_key(resource, attribute.name)

          case get_in(schemas, [type, Access.key(:properties), :attributes]) do
            %{properties: %{^key => field}} ->
              put_in(
                schemas,
                [type, Access.key(:properties), :attributes, Access.key(:properties), key],
                datetime(field)
              )

            _absent ->
              schemas
          end
      end

    %{spec | components: %{spec.components | schemas: schemas}}
  end

  defp datetime(%OpenAPISpex.Schema{} = schema),
    do: %{schema | type: :string, format: "date-time"}

  defp datetime(%{} = schema),
    do: Map.merge(schema, %{"type" => "string", "format" => "date-time"})

  defp nullable(%{"anyOf" => [_first, _second] = any_of} = schema) do
    case Enum.reject(any_of, &(&1 == %{"type" => "null"})) do
      [only] ->
        schema
        |> Map.delete("anyOf")
        |> Enum.reduce(nullable_schema(nullable(only)), fn {key, value}, acc ->
          put_field(acc, key, value)
        end)

      _other ->
        walk(schema)
    end
  end

  defp nullable(value), do: walk(value)

  defp walk(%_{} = struct),
    do:
      Map.new(Map.from_struct(struct), fn {key, value} -> {key, nullable(value)} end)
      |> then(&struct(struct, &1))

  defp walk(%{} = map), do: Map.new(map, fn {key, value} -> {key, nullable(value)} end)
  defp walk(list) when is_list(list), do: Enum.map(list, &nullable/1)
  defp walk(value), do: value

  defp nullable_schema(%OpenAPISpex.Schema{} = schema), do: %{schema | nullable: true}
  defp nullable_schema(%{} = schema), do: Map.put(schema, "nullable", true)

  defp put_field(%OpenAPISpex.Schema{} = schema, "description", description),
    do: %{schema | description: description}

  defp put_field(%{} = schema, key, value), do: Map.put(schema, key, value)

  defp title(:site), do: "Ankole site API v2"
  defp title(:console), do: "Ankole Console API v2"
end
