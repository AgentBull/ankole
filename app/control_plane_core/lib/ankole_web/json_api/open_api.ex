defmodule AnkoleWeb.JSONAPI.OpenAPI do
  @moduledoc """
  Completes the OpenAPI document of a JSON:API router.

  AshJsonApi derives the paths and schemas from the `json_api` sections. This
  module sets the title, the version, and the Console session security scheme
  of `AnkoleWeb.APISpec`. `mix ankole.openapi.check` keeps the committed
  documents current.
  """

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Info

  @version "2026-10-23"

  @doc """
  The `modify_open_api` function of a JSON:API router.

  AshJsonApi writes a nullable value as `anyOf` with `{"type": "null"}`, which
  is OpenAPI 3.1. The document declares 3.1, so that the generated client
  types a nullable value as `T | null`, not as `unknown`.
  """
  def modify(spec, _conn, _opts, scope) do
    %{
      spec
      | openapi: "3.1.0",
        info: %Info{title: title(scope), version: @version},
        components: %{
          spec.components
          | securitySchemes: %{"consoleSession" => AnkoleWeb.APISpec.console_session()}
        },
        security: [%{"consoleSession" => []}]
    }
  end

  defp title(:site), do: "Ankole site API v2"
  defp title(:console), do: "Ankole Console API v2"
end
