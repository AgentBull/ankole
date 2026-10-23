defmodule AnkoleWeb.APISpec do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.OpenApi, as: OpenAPI

  @moduledoc """
  OpenAPI description for the console SPA's generated client.
  """

  @behaviour OpenAPI

  alias OpenAPISpex.Components
  alias OpenAPISpex.Info
  alias OpenAPISpex.Paths
  alias OpenAPISpex.SecurityScheme
  alias OpenAPISpex.Server
  alias OpenAPISpex.Tag

  @impl OpenAPI
  def spec do
    # Paths are derived from the router's `operation/2` specs, so the document
    # always tracks the actual versioned routes. `version` is date-stamped rather
    # than semver.
    %OpenAPI{
      servers: [Server.from_endpoint(AnkoleWeb.Endpoint)],
      info: %Info{
        title: "Ankole API",
        version: "2026-09-04"
      },
      paths:
        AnkoleWeb.Router.__routes__()
        |> Enum.reject(fn route ->
          String.starts_with?(route.path, "/.internal-apis/") and
            not (route.path == "/.internal-apis/session" and route.verb == :delete)
        end)
        |> Paths.from_routes(),
      # Console requests use browser sessions. AIGateway uses Agent and OIDC Human tokens.
      components: %Components{
        securitySchemes: %{
          "consoleSession" => console_session(),
          "aiGatewayBearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT"
          }
        }
      },
      tags: [
        %Tag{
          name: "Auth",
          description: "Session-backed console authentication endpoints"
        },
        %Tag{
          name: "AppConfigure",
          description: "Registry-backed runtime configuration exposed to the web console"
        },
        %Tag{
          name: "WorkerEnv",
          description: "Operator-managed environment variables for Agent Computer shells"
        },
        %Tag{
          name: "Agents",
          description: "Operator-managed agent principals"
        },
        %Tag{
          name: "Principals",
          description: "Active accountable subjects available to operator surfaces"
        },
        %Tag{
          name: "AuthZ",
          description: "Principal groups, memberships, and permission grants"
        },
        %Tag{
          name: "LLM Runtime",
          description: "Operator-managed LLM provider and agent model profile configuration"
        },
        %Tag{
          name: "Identity Providers",
          description: "Operator-managed identity-provider configuration and directory sync"
        },
        %Tag{
          name: "AIGateway",
          description: "Agent and OIDC Human AI provider gateway"
        },
        %Tag{
          name: "Signal Bindings",
          description: "Operator-managed agent bindings for signal adapters"
        },
        %Tag{
          name: "Sessions",
          description: "Operator-visible Sessions for one Agent"
        },
        %Tag{
          name: "Workers",
          description: "Agent computer worker registry and worker filesystem management"
        },
        %Tag{
          name: "Background Agent Jobs",
          description: "Durable background Agent work executed by CodexRunner"
        }
      ]
    }
    |> OpenAPISpex.resolve_schema_modules()
  end

  @doc "Gives the security scheme of a Console request. The JSON:API documents use it too."
  def console_session,
    do: %SecurityScheme{
      type: "apiKey",
      in: "header",
      name: "Cookie",
      description:
        "The browser sends the sealed group and selected authentication cookies in the Cookie header. The group alone is not authentication. The shell supplies x-ankole-authentication for selection and x-csrf-token for unsafe requests."
    }
end
