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

  @doc "The `modify_open_api` function of a JSON:API router."
  def modify(spec, _conn, _opts, scope) do
    %{
      spec
      | info: %Info{title: title(scope), version: @version},
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
