defmodule BullXWeb.ApiSpec do
  @moduledoc """
  Builds the OpenAPI document served from `/.well-known/service-desc`.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{
    Components,
    Info,
    MediaType,
    OpenApi,
    Operation,
    PathItem,
    Paths,
    Response,
    Schema,
    SecurityScheme,
    Server,
    Tag
  }

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(BullXWeb.Endpoint)],
      info: %Info{
        title: "BullX API",
        version: to_string(Application.spec(:bullx, :vsn))
      },
      tags: [
        %Tag{name: "Channels", description: "Channel source management for the console."}
      ],
      components: %Components{
        securitySchemes: %{
          "cookieAuth" => %SecurityScheme{
            type: "apiKey",
            in: "cookie",
            name: "_bullx_key",
            description: "Session cookie issued after sign-in."
          }
        }
      },
      security: [%{"cookieAuth" => []}],
      paths: paths()
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp paths do
    BullXWeb.Router
    |> Paths.from_router()
    |> Map.put_new(
      "/.well-known/service-desc",
      spec_document_path("BullXWeb.ApiSpec.service_desc", "Well-known service description")
    )
  end

  defp spec_document_path(operation_id, summary) do
    %PathItem{
      get: %Operation{
        tags: ["System"],
        summary: summary,
        operationId: operation_id,
        security: [],
        responses: %{
          200 => %Response{
            description: "OpenAPI document.",
            content: %{
              "application/json" => %MediaType{
                schema: %Schema{type: :object}
              }
            }
          }
        }
      }
    }
  end
end
