defmodule AnkoleWeb.ApiSpec do
  @moduledoc """
  OpenAPI description for the stateless console REST API.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Paths
  alias OpenApiSpex.SecurityScheme
  alias OpenApiSpex.Server
  alias OpenApiSpex.Tag

  @impl OpenApiSpex.OpenApi
  def spec do
    # Paths are derived from the router's `operation/2` specs, so the document
    # always tracks the actual console routes. `version` is date-stamped rather
    # than semver — the console API is versioned by calendar date.
    %OpenApi{
      servers: [Server.from_endpoint(AnkoleWeb.Endpoint)],
      info: %Info{
        title: "Ankole Console API",
        version: "2026-06-24"
      },
      paths: Paths.from_router(AnkoleWeb.Router),
      # The documented `consoleBearer` scheme is the spec-side mirror of
      # RequireConsoleAccessToken; controllers reference it via `security/1`.
      components: %Components{
        securitySchemes: %{
          "consoleBearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT"
          }
        }
      },
      tags: [
        %Tag{
          name: "AppConfigure",
          description: "Registry-backed runtime configuration exposed to the web console"
        },
        %Tag{
          name: "LLM Runtime",
          description: "Operator-managed LLM provider and agent model profile configuration"
        },
        %Tag{
          name: "Schedule",
          description: "Operator-visible actor checkbacks and recurring schedules"
        }
      ]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
