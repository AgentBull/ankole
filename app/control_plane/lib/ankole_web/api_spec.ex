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
    %OpenApi{
      servers: [Server.from_endpoint(AnkoleWeb.Endpoint)],
      info: %Info{
        title: "Ankole Console API",
        version: "2026-06-24"
      },
      paths: Paths.from_router(AnkoleWeb.Router),
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
        }
      ]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
