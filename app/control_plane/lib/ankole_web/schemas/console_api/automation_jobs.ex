defmodule AnkoleWeb.Schemas.ConsoleAPI.AutomationJobRunItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AutomationJobRunItem",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, minimum: 1000, maximum: 9_007_199_254_740_991},
        status: %Schema{
          type: :string,
          enum: ["queued", "running", "succeeded", "failed", "cancelled"]
        },
        attempts: %Schema{type: :integer, minimum: 0},
        started_at: %Schema{type: :string, format: :"date-time", nullable: true},
        finished_at: %Schema{type: :string, format: :"date-time", nullable: true},
        exit_code: %Schema{type: :integer, nullable: true},
        error: %Schema{type: :string, nullable: true},
        stdout: %Schema{type: :string},
        stderr: %Schema{type: :string}
      },
      required: [:id, :status, :attempts, :stdout, :stderr],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AutomationJobItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AutomationJobRunItem
  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AutomationJobItem",
      type: :object,
      properties: %{
        id: %Schema{type: :integer, minimum: 1000, maximum: 9_007_199_254_740_991},
        agent_uid: %Schema{type: :string},
        owner_session_id: %Schema{type: :string},
        source_signal_id: %Schema{type: :string, format: :uuid, nullable: true},
        provider_message_id: %Schema{type: :string, nullable: true},
        source_provenance: JSONValue,
        reply_route: JSONValue,
        drive_prefix: %Schema{type: :string},
        label: %Schema{type: :string},
        wake_on_failure: %Schema{type: :boolean},
        status: %Schema{type: :string, enum: ["active", "cancelled", "expired"]},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        cancelled_at: %Schema{type: :string, format: :"date-time", nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"},
        runs: %Schema{type: :array, items: AutomationJobRunItem}
      },
      required: [
        :id,
        :agent_uid,
        :owner_session_id,
        :source_provenance,
        :reply_route,
        :drive_prefix,
        :label,
        :wake_on_failure,
        :status,
        :created_at,
        :updated_at,
        :runs
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AutomationJobResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AutomationJobItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AutomationJobResponse",
      type: :object,
      properties: %{automation_job: AutomationJobItem},
      required: [:automation_job],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AutomationJobListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AutomationJobItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AutomationJobListResponse",
      type: :object,
      properties: %{
        automation_jobs: %Schema{type: :array, items: AutomationJobItem}
      },
      required: [:automation_jobs],
      additionalProperties: false
    },
    struct?: false
  )
end
