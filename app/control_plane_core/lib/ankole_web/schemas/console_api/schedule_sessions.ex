defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleOccurrences do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleOccurrences",
      description:
        "Bound of a recurring schedule: exactly one of `count` (due slots to run) or `until` (inclusive cutoff instant).",
      type: :object,
      properties: %{
        count: %Schema{type: :integer, minimum: 1},
        until: %Schema{
          type: :string,
          description:
            "ISO 8601 instant, or a local time that the schedule timezone resolves. Stored as UTC."
        }
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleRecurrence do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleOccurrences

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleRecurrence",
      description:
        "Recurrence of one cron schedule. Kind `cron` uses `expression` and `timezone`; kind `every` uses `every_ms` and `anchor_at`.",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: ["cron", "every"]},
        expression: %Schema{
          type: :string,
          minLength: 1,
          description: "Crontab expression with five fields, or six fields with leading seconds."
        },
        timezone: %Schema{
          type: :string,
          description:
            "IANA timezone. A write can omit it and give the request `timezone` instead. A stored `cron` recurrence carries it."
        },
        every_ms: %Schema{type: :integer, minimum: 1, description: "Interval in milliseconds."},
        anchor_at: %Schema{
          type: :string,
          description: "ISO 8601 instant that the interval counts from."
        },
        occurrences: ScheduleOccurrences
      },
      required: [:kind],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.SchedulePayload do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "SchedulePayload",
      description:
        "Standing input of every fire. `task` is the self-contained instruction of a direct-Agent schedule; it is required unless an automation job consumes the trigger. Other keys pass through unchanged.",
      type: :object,
      additionalProperties: true
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleDeliveryTarget do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleDeliveryTarget",
      oneOf: [
        %Schema{
          type: :object,
          properties: %{conversation_id: %Schema{type: :string, format: :uuid}},
          required: [:conversation_id],
          additionalProperties: false
        },
        %Schema{
          type: :object,
          properties: %{
            binding_name: %Schema{type: :string, minLength: 1},
            conversation_id: %Schema{type: :string, format: :uuid},
            provider_thread_id: %Schema{type: :string}
          },
          required: [:binding_name, :conversation_id],
          additionalProperties: false
        }
      ]
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleDelivery do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleDeliveryTarget

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleDelivery",
      description:
        "Where the result of a fire goes. A target is a native conversation ID or an external reply route. An external primary target uses the schedule `binding_name`; a native primary target has no binding. When `quiet_success` is true, a fire with nothing to report sends no message. An update that omits `quiet_success` keeps the stored value.",
      type: :object,
      properties: %{
        targets: %Schema{type: :array, items: ScheduleDeliveryTarget, minItems: 1},
        quiet_success: %Schema{type: :boolean}
      },
      required: [:targets],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.CronScheduleItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleDelivery
  alias AnkoleWeb.Schemas.ConsoleAPI.SchedulePayload
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleRecurrence

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "CronScheduleItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ["active", "paused", "deleted", "completed"]},
        agent_uid: %Schema{type: :string},
        owner_session_id: %Schema{type: :string},
        execution_session_id: %Schema{
          type: :string,
          description: "Derived session `cron:<id>` where every fire runs."
        },
        binding_name: %Schema{type: :string, nullable: true},
        name: %Schema{type: :string},
        schedule: ScheduleRecurrence,
        timezone: %Schema{type: :string},
        payload: SchedulePayload,
        delivery: %Schema{allOf: [ScheduleDelivery], nullable: true},
        next_fire_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_fire_at: %Schema{type: :string, format: :"date-time", nullable: true},
        idempotency_key: %Schema{type: :string},
        created_by: %Schema{
          type: :object,
          additionalProperties: true,
          description: "Origin of the schedule; `kind` names the writer."
        },
        automation_job_id: %Schema{type: :integer, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :status,
        :agent_uid,
        :owner_session_id,
        :execution_session_id,
        :binding_name,
        :name,
        :schedule,
        :timezone,
        :payload,
        :delivery,
        :next_fire_at,
        :last_fire_at,
        :idempotency_key,
        :created_by,
        :automation_job_id,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduledEventItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduledEventItem",
      description: "One concrete fire: a one-shot checkback or one slot of a cron schedule.",
      type: :object,
      properties: %{
        id: %Schema{type: :integer},
        kind: %Schema{type: :string, enum: ["check_back_later", "cron_fire"]},
        status: %Schema{
          type: :string,
          enum: ["scheduled", "fired", "cancelled", "failed"]
        },
        agent_uid: %Schema{type: :string},
        session_id: %Schema{type: :string},
        binding_name: %Schema{type: :string, nullable: true},
        due_at: %Schema{type: :string, format: :"date-time"},
        timezone: %Schema{type: :string},
        requested_at: %Schema{type: :string, format: :"date-time"},
        idempotency_key: %Schema{type: :string},
        cron_schedule_id: %Schema{type: :string, format: :uuid, nullable: true},
        automation_job_id: %Schema{type: :integer, nullable: true},
        automation_job_run_id: %Schema{type: :integer, nullable: true},
        cron_fire_slot_at: %Schema{type: :string, format: :"date-time", nullable: true},
        tool_call_id: %Schema{type: :string, nullable: true},
        origin_ai_message_id: %Schema{type: :string, format: :uuid, nullable: true},
        source_signal_id: %Schema{type: :string, format: :uuid, nullable: true},
        conversation_id: %Schema{type: :string, nullable: true},
        provider_thread_id: %Schema{type: :string, nullable: true},
        provider_message_id: %Schema{type: :string, nullable: true},
        source_provenance: %Schema{type: :object, additionalProperties: true},
        wake_payload: %Schema{
          type: :object,
          additionalProperties: true,
          description:
            "Input of the wake turn. A checkback carries `reason`, `check`, and `context_summary`; a cron fire carries `trigger` and the frozen schedule facts."
        },
        signal_id: %Schema{type: :string, format: :uuid, nullable: true},
        fired_at: %Schema{type: :string, format: :"date-time", nullable: true},
        cancelled_at: %Schema{type: :string, format: :"date-time", nullable: true},
        last_fire_error: %Schema{
          type: :object,
          additionalProperties: true,
          description:
            "Stored diagnostic of the last cancellation or failure; `reason` names it. Empty when there is none."
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :id,
        :kind,
        :status,
        :agent_uid,
        :session_id,
        :binding_name,
        :due_at,
        :timezone,
        :requested_at,
        :idempotency_key,
        :cron_schedule_id,
        :automation_job_id,
        :automation_job_run_id,
        :cron_fire_slot_at,
        :tool_call_id,
        :origin_ai_message_id,
        :source_signal_id,
        :conversation_id,
        :provider_thread_id,
        :provider_message_id,
        :source_provenance,
        :wake_payload,
        :signal_id,
        :fired_at,
        :cancelled_at,
        :last_fire_error,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleDelivery
  alias AnkoleWeb.Schemas.ConsoleAPI.SchedulePayload
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleRecurrence

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleCronWriteRequest",
      type: :object,
      properties: %{
        owner_session_id: %Schema{
          type: :string,
          minLength: 1,
          description:
            "Conversation session that manages this schedule. Fires run in the derived execution session `cron:<schedule_id>`."
        },
        binding_name: %Schema{type: :string, nullable: true},
        name: %Schema{type: :string, minLength: 1},
        status: %Schema{type: :string, enum: ["active", "paused"], nullable: true},
        schedule: ScheduleRecurrence,
        timezone: %Schema{type: :string, nullable: true},
        payload: SchedulePayload,
        delivery: ScheduleDelivery,
        idempotency_key: %Schema{type: :string}
      },
      required: [
        :owner_session_id,
        :name,
        :schedule,
        :delivery,
        :idempotency_key
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleDelivery
  alias AnkoleWeb.Schemas.ConsoleAPI.SchedulePayload
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduleRecurrence

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleCronUpdateRequest",
      type: :object,
      minProperties: 1,
      properties: %{
        name: %Schema{type: :string, minLength: 1},
        schedule: ScheduleRecurrence,
        timezone: %Schema{type: :string, nullable: true},
        payload: SchedulePayload,
        delivery: ScheduleDelivery
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronScheduleResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.CronScheduleItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleCronScheduleResponse",
      type: :object,
      properties: %{cron_schedule: CronScheduleItem},
      required: [:cron_schedule],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleCronScheduleListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.CronScheduleItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleCronScheduleListResponse",
      type: :object,
      properties: %{cron_schedules: %Schema{type: :array, items: CronScheduleItem}},
      required: [:cron_schedules],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleEventResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduledEventItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleEventResponse",
      type: :object,
      properties: %{schedule_event: ScheduledEventItem},
      required: [:schedule_event],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleEventListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduledEventItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleEventListResponse",
      type: :object,
      properties: %{schedule_events: %Schema{type: :array, items: ScheduledEventItem}},
      required: [:schedule_events],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ScheduleRunListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ScheduledEventItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ScheduleRunListResponse",
      type: :object,
      properties: %{schedule_runs: %Schema{type: :array, items: ScheduledEventItem}},
      required: [:schedule_runs],
      additionalProperties: false
    },
    struct?: false
  )
end

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
