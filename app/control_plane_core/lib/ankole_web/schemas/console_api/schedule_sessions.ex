defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentSession do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentSession",
      type: :object,
      description: "One Session surfaced from durable schedule, Signal, or job rows.",
      properties: %{
        session_id: %Schema{type: :string},
        kind: %Schema{
          type: :string,
          enum: ["job", "session"],
          description: "`job` marks a background-agent-job session (id `\"job:<id>\"`)."
        },
        title: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, nullable: true},
        last_activity_at: %Schema{type: :string, nullable: true}
      },
      required: [:session_id, :kind],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentSessionListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentSession

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentSessionListResponse",
      type: :object,
      properties: %{sessions: %Schema{type: :array, items: AgentSession}},
      required: [:sessions],
      additionalProperties: false
    },
    struct?: false
  )
end
