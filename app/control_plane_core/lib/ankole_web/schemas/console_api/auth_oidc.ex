defmodule AnkoleWeb.Schemas.ConsoleAPI.AuthSessionDeleteResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AuthSessionDeleteResponse",
      type: :object,
      properties: %{
        ok: %Schema{type: :boolean}
      },
      required: [:ok],
      additionalProperties: false
    },
    struct?: false
  )
end
