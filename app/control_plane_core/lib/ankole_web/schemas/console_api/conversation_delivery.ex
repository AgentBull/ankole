defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryRequeueRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalDeliveryRequeueRequest",
      type: :object,
      properties: %{
        binding_name: %Schema{type: :string, minLength: 1},
        outbound_key: %Schema{type: :string, minLength: 1}
      },
      required: [:binding_name, :outbound_key],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryFailureItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalDeliveryFailureItem",
      type: :object,
      properties: %{
        agent_uid: %Schema{type: :string},
        binding_name: %Schema{type: :string},
        outbound_key: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["failed", "expired", "unknown"]},
        state: %Schema{
          type: :string,
          enum: ["blocked", "permanent", "exhausted"]
        },
        attempt_count: %Schema{type: :integer, minimum: 0},
        max_attempts: %Schema{type: :integer, minimum: 1},
        possible_duplicate: %Schema{type: :boolean},
        can_retry: %Schema{type: :boolean},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :agent_uid,
        :binding_name,
        :outbound_key,
        :status,
        :state,
        :attempt_count,
        :max_attempts,
        :possible_duplicate,
        :can_retry,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SignalDeliveryRequeueResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SignalDeliveryRequeueResponse",
      type: :object,
      properties: %{requeued: %Schema{type: :boolean}},
      required: [:requeued],
      additionalProperties: false
    },
    struct?: false
  )
end
