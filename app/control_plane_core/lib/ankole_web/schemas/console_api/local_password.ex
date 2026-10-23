defmodule AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "LocalPasswordResetRequest",
      type: :object,
      properties: %{
        must_change_password: %Schema{type: :boolean, default: true}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.LocalPasswordResetResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "LocalPasswordResetResponse",
      type: :object,
      properties: %{
        initial_password: %Schema{type: :string}
      },
      required: [:initial_password],
      additionalProperties: false
    },
    struct?: false
  )
end
