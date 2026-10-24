defmodule AnkoleWeb.JSONAPI.OpenAPI do
  @moduledoc """
  Completes the OpenAPI document of a JSON:API router.

  AshJsonApi derives the paths and schemas from the `json_api` sections. This
  module sets the title, the version, and the Console session security scheme
  for the browser. `mix ankole.openapi.check` keeps the committed
  documents current.
  """

  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Info
  alias OpenAPISpex.SecurityScheme

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
          | securitySchemes: %{"consoleSession" => console_session()}
        },
        security: [%{"consoleSession" => []}]
    }
  end

  @doc "Gives the browser session security scheme for the Console documents."
  def console_session,
    do: %SecurityScheme{
      type: "apiKey",
      in: "header",
      name: "Cookie",
      description:
        "The browser sends the sealed group and selected authentication cookies in the Cookie header. The group alone is not authentication. The shell supplies x-ankole-authentication for selection and x-csrf-token for unsafe requests."
    }

  defp title(:saas), do: "Ankole SaaS account API v2"
  defp title(:browser), do: "Ankole browser authentication and setup API v2"
  defp title(:pod), do: "Ankole Pod API v2"
  defp title(:site), do: "Ankole site API v2"
  defp title(:console), do: "Ankole Console API v2"
end
