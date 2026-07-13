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
        version: "2026-07-09"
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
          },
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
          name: "Codex Accounts",
          description: "Operator-managed ChatGPT subscription accounts used by coding profiles"
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
          description: "Agent-authenticated AI provider gateway"
        },
        %Tag{
          name: "Signal Bindings",
          description: "Operator-managed agent bindings for signal adapters"
        },
        %Tag{
          name: "Schedule",
          description: "Operator-visible actor checkbacks and recurring schedules"
        },
        %Tag{
          name: "Workers",
          description: "Agent computer worker registry and worker filesystem management"
        },
        %Tag{
          name: "Subagent Delegations",
          description: "Durable background work delegated to the task-worker runtime"
        },
        %Tag{
          name: "Brain",
          description: "Human supervision of current knowledge, provenance, and audit recovery"
        }
      ]
    }
    |> OpenAPISpex.resolve_schema_modules()
  end
end
