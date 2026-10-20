defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnUsageBreakdown do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  @token_count %Schema{type: :integer, minimum: 0}

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnUsageBreakdown",
      type: :object,
      properties: %{
        total_tokens: @token_count,
        input_tokens: @token_count,
        cached_input_tokens: @token_count,
        output_tokens: @token_count,
        reasoning_output_tokens: @token_count
      },
      required: [
        :total_tokens,
        :input_tokens,
        :cached_input_tokens,
        :output_tokens,
        :reasoning_output_tokens
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnUsage do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnUsageBreakdown

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnUsage",
      type: :object,
      properties: %{
        thread_total: BackgroundAgentJobTurnUsageBreakdown,
        last_model_call: BackgroundAgentJobTurnUsageBreakdown,
        model_context_window: %Schema{type: :integer, minimum: 0}
      },
      required: [:thread_total, :last_model_call],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnToolUsage do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnToolUsage",
      type: :object,
      properties: %{
        namespace: %Schema{type: :string, minLength: 1},
        name: %Schema{type: :string, minLength: 1},
        calls: %Schema{type: :integer, minimum: 0}
      },
      required: [:name, :calls],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnToolExecutionMechanism do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnToolExecutionMechanism",
      type: :object,
      properties: %{
        namespace: %Schema{type: :string, minLength: 1},
        name: %Schema{type: :string, minLength: 1},
        execution_mechanism: %Schema{
          type: :string,
          enum: ["local_dynamic", "provider_hosted"]
        },
        calls: %Schema{type: :integer, minimum: 1}
      },
      required: [:name, :execution_mechanism, :calls],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnPlanStep do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnPlanStep",
      type: :object,
      properties: %{
        step: %Schema{type: :string, minLength: 1},
        status: %Schema{type: :string, enum: ["pending", "in_progress", "completed"]}
      },
      required: [:step, :status],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnPlan do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnPlanStep

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnPlan",
      type: :object,
      properties: %{
        explanation: %Schema{type: :string},
        steps: %Schema{type: :array, items: BackgroundAgentJobTurnPlanStep, maxItems: 100}
      },
      required: [:steps],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnActiveItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnActiveItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string, minLength: 1},
        namespace: %Schema{type: :string, minLength: 1},
        name: %Schema{type: :string, minLength: 1}
      },
      required: [:id, :name],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnProgress do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnActiveItem
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnPlan
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnToolExecutionMechanism
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnToolUsage

  @moduledoc false
  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnProgress",
      type: :object,
      properties: %{
        completed_items: %Schema{type: :integer, minimum: 0},
        tool_calls: %Schema{type: :integer, minimum: 0},
        tools_used: %Schema{type: :array, items: BackgroundAgentJobTurnToolUsage, maxItems: 128},
        tool_execution_mechanisms: %Schema{
          type: :array,
          items: BackgroundAgentJobTurnToolExecutionMechanism,
          maxItems: 256
        },
        files_changed: %Schema{type: :array, items: %Schema{type: :string}, maxItems: 1024},
        plan: BackgroundAgentJobTurnPlan,
        active_item: BackgroundAgentJobTurnActiveItem
      },
      required: [:completed_items, :tool_calls, :tools_used, :files_changed],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnProgress
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnUsage

  @moduledoc false

  require OpenAPISpex

  @kinds Ankole.BackgroundAgentJobs.TurnState.kinds()
  @statuses Ankole.BackgroundAgentJobs.TurnState.statuses()

  @content_part %Schema{
    type: :object,
    properties: %{type: %Schema{type: :string}},
    required: [:type],
    additionalProperties: true
  }
  @user_content %Schema{
    oneOf: [
      %Schema{type: :string},
      %Schema{type: :array, items: @content_part}
    ]
  }
  @tool_call %Schema{
    type: :object,
    properties: %{
      id: %Schema{type: :string},
      type: %Schema{type: :string, enum: ["function"]},
      function: %Schema{
        type: :object,
        properties: %{
          namespace: %Schema{type: :string},
          name: %Schema{type: :string},
          arguments: %Schema{type: :string}
        },
        required: [:name, :arguments],
        additionalProperties: true
      }
    },
    required: [:id, :type, :function],
    additionalProperties: true
  }
  @message_metadata %Schema{type: :object, additionalProperties: true}
  @message %Schema{
    oneOf: [
      %Schema{
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          role: %Schema{type: :string, enum: ["user", "developer"]},
          content: @user_content,
          metadata: @message_metadata
        },
        required: [:role, :content],
        additionalProperties: true
      },
      %Schema{
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          role: %Schema{type: :string, enum: ["assistant"]},
          content: %Schema{type: :string},
          tool_calls: %Schema{type: :array, items: @tool_call},
          metadata: @message_metadata
        },
        required: [:role, :content],
        additionalProperties: true
      },
      %Schema{
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          role: %Schema{type: :string, enum: ["tool"]},
          tool_call_id: %Schema{type: :string},
          namespace: %Schema{type: :string},
          name: %Schema{type: :string},
          content: %Schema{type: :string},
          metadata: @message_metadata
        },
        required: [:role, :tool_call_id, :name, :content],
        additionalProperties: true
      }
    ]
  }

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobTurnItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        attempt: %Schema{type: :integer},
        runtime_thread_id: %Schema{type: :string},
        runtime_turn_id: %Schema{type: :string},
        kind: %Schema{type: :string, enum: @kinds},
        status: %Schema{type: :string, enum: @statuses},
        revision: %Schema{type: :integer},
        trajectory: %Schema{
          type: :object,
          additionalProperties: false,
          properties: %{
            format: %Schema{type: :string, enum: ["ankole_chatml"]},
            version: %Schema{type: :integer, enum: [1]},
            messages: %Schema{
              type: :array,
              items: @message
            },
            metadata: %Schema{
              type: :object,
              properties: %{
                redacted: %Schema{type: :boolean},
                content_truncated: %Schema{type: :boolean}
              },
              additionalProperties: false
            }
          },
          required: [:format, :version, :messages]
        },
        progress: BackgroundAgentJobTurnProgress,
        usage: %Schema{allOf: [BackgroundAgentJobTurnUsage], nullable: true},
        error: %Schema{type: :object, additionalProperties: true},
        started_at: %Schema{type: :string},
        completed_at: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string}
      },
      required: [
        :id,
        :attempt,
        :runtime_thread_id,
        :runtime_turn_id,
        :kind,
        :status,
        :revision,
        :trajectory,
        :progress,
        :usage,
        :error,
        :started_at,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobTurnItem

  @moduledoc false

  require OpenAPISpex

  @statuses Ankole.BackgroundAgentJobs.JobState.statuses()

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobItem",
      type: :object,
      properties: %{
        id: %Schema{
          type: :integer,
          minimum: Ankole.ModelIntegerID.minimum(),
          maximum: Ankole.ModelIntegerID.maximum()
        },
        agent_uid: %Schema{type: :string},
        owner_session_id: %Schema{type: :string},
        source_signal_id: %Schema{type: :string, nullable: true},
        source_tool_call_id: %Schema{type: :string},
        runtime_thread_id: %Schema{type: :string, nullable: true},
        title: %Schema{type: :string},
        task: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: @statuses
        },
        attempts: %Schema{type: :integer},
        execution_failures: %Schema{type: :integer},
        workspace_template_id: %Schema{type: :string, nullable: true},
        model_profile: %Schema{type: :string},
        reply_route: %Schema{type: :object, additionalProperties: true},
        result: %Schema{type: :object, additionalProperties: true},
        error: %Schema{type: :object, additionalProperties: true},
        metadata: %Schema{type: :object, additionalProperties: true},
        duration_seconds: %Schema{type: :integer},
        queued_at: %Schema{type: :string, nullable: true},
        started_at: %Schema{type: :string, nullable: true},
        completed_at: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string},
        turns: %Schema{
          type: :array,
          items: BackgroundAgentJobTurnItem,
          description:
            "One bounded page of runtime Turns, newest Turns first, in chronological order."
        },
        turns_next_cursor: %Schema{
          type: :string,
          nullable: true,
          description: "Opaque cursor for the page of older Turns; null on the last page."
        }
      },
      required: [
        :id,
        :agent_uid,
        :owner_session_id,
        :source_tool_call_id,
        :title,
        :task,
        :status,
        :attempts,
        :execution_failures,
        :workspace_template_id,
        :model_profile,
        :reply_route,
        :result,
        :error,
        :metadata,
        :duration_seconds,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobListItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  @statuses Ankole.BackgroundAgentJobs.JobState.statuses()

  # One board row. A list page carries up to 100 of these and reloads on a
  # timer, so it stays at what the board and the home panel draw. The queued
  # prompt, the result, the error, and the metadata grow with the work the job
  # did and belong to the single-job read.
  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobListItem",
      type: :object,
      properties: %{
        id: %Schema{
          type: :integer,
          minimum: Ankole.ModelIntegerID.minimum(),
          maximum: Ankole.ModelIntegerID.maximum()
        },
        agent_uid: %Schema{type: :string},
        title: %Schema{type: :string},
        status: %Schema{
          type: :string,
          enum: @statuses
        },
        attempts: %Schema{type: :integer},
        execution_failures: %Schema{type: :integer},
        workspace_template_id: %Schema{type: :string, nullable: true},
        duration_seconds: %Schema{type: :integer},
        inserted_at: %Schema{type: :string}
      },
      required: [
        :id,
        :agent_uid,
        :title,
        :status,
        :attempts,
        :execution_failures,
        :workspace_template_id,
        :duration_seconds,
        :inserted_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobListItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobListResponse",
      type: :object,
      properties: %{
        jobs: %Schema{type: :array, items: BackgroundAgentJobListItem},
        next_cursor: %Schema{type: :string, nullable: true}
      },
      required: [:jobs, :next_cursor],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobHealthResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  # Reliability trend signals, not exact ledgers: the 24-hour sums read
  # recently updated Job rows. `claims_24h` counts every worker-attempt
  # claim; `execution_failures_24h` counts only failures charged to the
  # execution budget, so the gap between them is infrastructure churn.
  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobHealthResponse",
      type: :object,
      properties: %{
        oldest_queued_seconds: %Schema{type: :integer, nullable: true},
        queued_count: %Schema{type: :integer},
        running_count: %Schema{type: :integer},
        max_running_per_agent: %Schema{type: :integer},
        agents_at_running_cap: %Schema{type: :integer},
        queued_behind_running_cap: %Schema{type: :integer},
        claims_24h: %Schema{type: :integer},
        execution_failures_24h: %Schema{type: :integer},
        succeeded_24h: %Schema{type: :integer},
        successor_seeded_24h: %Schema{type: :integer},
        wakeups_24h: %Schema{type: :integer},
        dead_letter_notices_24h: %Schema{type: :integer},
        window_seconds: %Schema{type: :integer}
      },
      required: [
        :oldest_queued_seconds,
        :queued_count,
        :running_count,
        :max_running_per_agent,
        :agents_at_running_cap,
        :queued_behind_running_cap,
        :claims_24h,
        :execution_failures_24h,
        :succeeded_24h,
        :successor_seeded_24h,
        :wakeups_24h,
        :dead_letter_notices_24h,
        :window_seconds
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.BackgroundAgentJobItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "BackgroundAgentJobResponse",
      type: :object,
      properties: %{
        job: BackgroundAgentJobItem
      },
      required: [:job],
      additionalProperties: false
    },
    struct?: false
  )
end
