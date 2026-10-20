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

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayConversationItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayConversationItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        subject_uid: %Schema{type: :string},
        conversation_key: %Schema{type: :string},
        kind: %Schema{
          type: :string,
          enum: ["conversation", "signal", "dreaming", "job", "cron", "responses_api", "custom"]
        },
        display_name: %Schema{type: :string, nullable: true},
        channel_kind: %Schema{
          type: :string,
          enum: ["im_dm", "im_group", "webhook_endpoint", "issue", "alert_stream", "unknown"],
          nullable: true
        },
        signal_adapter: %Schema{type: :string, nullable: true},
        message_count: %Schema{type: :integer},
        ended_at: %Schema{type: :string, nullable: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string}
      },
      required: [
        :id,
        :subject_uid,
        :conversation_key,
        :kind,
        :display_name,
        :channel_kind,
        :signal_adapter,
        :message_count,
        :metadata,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayConversationListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayConversationItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayConversationListResponse",
      type: :object,
      properties: %{
        conversations: %Schema{type: :array, items: AIGatewayConversationItem},
        next_cursor: %Schema{type: :string, nullable: true}
      },
      required: [:conversations, :next_cursor],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayConversationResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayConversationItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayConversationResponse",
      type: :object,
      properties: %{
        conversation: AIGatewayConversationItem
      },
      required: [:conversation],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayMessageItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  @types ~w(message checkpoint)
  @statuses ~w(generating complete error retracted)

  OpenAPISpex.schema(
    %{
      title: "AIGatewayMessageItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        subject_uid: %Schema{type: :string},
        conversation_id: %Schema{type: :string},
        type: %Schema{type: :string, enum: @types},
        status: %Schema{type: :string, enum: @statuses},
        previous_message_id: %Schema{type: :string, nullable: true},
        content: %Schema{
          type: :array,
          items: %Schema{type: :object, additionalProperties: true}
        },
        metadata: %Schema{type: :object, additionalProperties: true},
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string}
      },
      required: [
        :id,
        :subject_uid,
        :conversation_id,
        :type,
        :status,
        :content,
        :metadata,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AIGatewayMessageListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayMessageItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AIGatewayMessageListResponse",
      type: :object,
      properties: %{
        messages: %Schema{type: :array, items: AIGatewayMessageItem},
        next_cursor: %Schema{type: :string, nullable: true}
      },
      required: [:messages, :next_cursor],
      additionalProperties: false
    },
    struct?: false
  )
end
