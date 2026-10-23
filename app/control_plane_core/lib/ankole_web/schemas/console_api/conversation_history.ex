defmodule AnkoleWeb.Schemas.ConsoleAPI.ConversationStandingOrdersWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConversationStandingOrdersWriteRequest",
      type: :object,
      properties: %{
        orders: %Schema{
          type: :string,
          maxLength: 4000,
          description: "Full replacement standing-orders text; empty clears them."
        }
      },
      required: [:orders],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConversationStandingOrdersItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConversationStandingOrdersItem",
      type: :object,
      properties: %{
        conversation_id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string, nullable: true},
        orders: %Schema{type: :string, nullable: true},
        set_by: %Schema{type: :string, nullable: true},
        updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:conversation_id],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConversationStandingOrdersResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ConversationStandingOrdersItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConversationStandingOrdersResponse",
      type: :object,
      properties: %{
        standing_orders: ConversationStandingOrdersItem
      },
      required: [:standing_orders],
      additionalProperties: false
    },
    struct?: false
  )
end
