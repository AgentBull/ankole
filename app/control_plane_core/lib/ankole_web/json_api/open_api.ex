defmodule AnkoleWeb.JSONAPI.OpenAPI do
  @moduledoc """
  Completes the OpenAPI document of a JSON:API router.

  AshJsonApi derives the paths and schemas from the `json_api` sections. This
  module sets the title, the version, and the Console session security scheme
  of `AnkoleWeb.APISpec`. `mix ankole.openapi.check` keeps the committed
  documents current.

  AshJsonApi 1.7.1 writes a nullable field as `anyOf: [schema, {type: null}]`.
  The `{type: null}` schema is not OpenAPI 3.0, and the generated TypeScript
  type of such a field is `unknown`. This module writes the field as the
  schema with `nullable: true`.
  """

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Info
  alias OpenAPISpex.Schema

  @version "2026-10-23"

  @doc "The `modify_open_api` function of a JSON:API router."
  def modify(spec, _conn, _opts, scope) do
    %{
      spec
      | info: %Info{title: title(scope), version: @version},
        components: %{
          spec.components
          | securitySchemes: %{"consoleSession" => AnkoleWeb.APISpec.console_session()},
            schemas: nullable(spec.components.schemas)
        },
        paths: nullable(spec.paths),
        security: [%{"consoleSession" => []}]
    }
  end

  defp title(:site), do: "Ankole site API v2"
  defp title(:console), do: "Ankole Console API v2"

  defp nullable(%{"anyOf" => [schema, %{"type" => "null"}]} = any_of) do
    description = any_of["description"]

    case nullable(schema) do
      %Schema{} = schema ->
        %{schema | nullable: true, description: schema.description || description}

      %{} = schema ->
        schema |> Map.put("nullable", true) |> put_description(description)
    end
  end

  defp nullable(%module{} = struct) do
    struct |> Map.from_struct() |> nullable() |> then(&struct(module, &1))
  end

  defp nullable(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, nullable(value)} end)

  defp nullable(list) when is_list(list), do: Enum.map(list, &nullable/1)
  defp nullable(value), do: value

  defp put_description(schema, nil), do: schema
  defp put_description(schema, description), do: Map.put_new(schema, "description", description)
end
