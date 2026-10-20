defmodule AnkoleWeb.InternalAPISpec do
  @moduledoc "Build-time browser API document. This document has no public route."
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.{Info, OpenApi, Paths}
  @behaviour OpenApi

  @impl OpenApi
  def spec do
    paths =
      AnkoleWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/.internal-apis/"))
      |> Paths.from_routes()

    %OpenApi{
      info: %Info{title: "Ankole private browser API", version: "2026-10-16"},
      paths: paths
    }
    |> OpenAPISpex.resolve_schema_modules()
  end
end
