defmodule AnkoleWeb.Schemas.BackgroundActivities do
  @moduledoc "Diagnostic rows preserve the three owners' native states and relationships."
  alias OpenApiSpex.Schema

  defmodule BackgroundActivityJob do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BackgroundActivityJob",
        type: :object,
        properties: %{
          id: %Schema{
            type: :integer,
            minimum: Ankole.ModelIntegerID.minimum(),
            maximum: Ankole.ModelIntegerID.maximum()
          },
          agent_uid: %Schema{type: :string},
          owner_session_id: %Schema{type: :string},
          resource_kind: %Schema{type: :string, enum: ["background_job"]},
          title: %Schema{type: :string},
          status: %Schema{type: :string, enum: ["queued", "running", "waiting_on_user"]},
          source_signal_id: %Schema{type: :string, nullable: true},
          attempts: %Schema{type: :integer, minimum: 0},
          error_code: %Schema{type: :string, nullable: true},
          error_summary: %Schema{type: :string, nullable: true},
          queued_at: %Schema{type: :string, format: :"date-time", nullable: true},
          started_at: %Schema{type: :string, format: :"date-time", nullable: true},
          updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
        },
        required: [
          :id,
          :agent_uid,
          :owner_session_id,
          :resource_kind,
          :title,
          :status,
          :source_signal_id,
          :attempts,
          :error_code,
          :error_summary,
          :queued_at,
          :started_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundActivityAutomationRun do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BackgroundActivityAutomationRun",
        type: :object,
        properties: %{
          id: %Schema{
            type: :integer,
            minimum: Ankole.ModelIntegerID.minimum(),
            maximum: Ankole.ModelIntegerID.maximum()
          },
          agent_uid: %Schema{type: :string},
          owner_session_id: %Schema{type: :string},
          resource_kind: %Schema{type: :string, enum: ["automation_run"]},
          automation_job_id: %Schema{
            type: :integer,
            minimum: Ankole.ModelIntegerID.minimum(),
            maximum: Ankole.ModelIntegerID.maximum()
          },
          label: %Schema{type: :string, nullable: true},
          definition_status: %Schema{type: :string, enum: ["active", "cancelled"]},
          status: %Schema{type: :string, enum: ["queued", "running"]},
          attempts: %Schema{type: :integer, minimum: 0},
          attempt_id: %Schema{type: :string, nullable: true},
          error: %Schema{type: :string, nullable: true},
          scheduled_event_id: %Schema{type: :string, nullable: true},
          started_at: %Schema{type: :string, format: :"date-time", nullable: true},
          inserted_at: %Schema{type: :string, format: :"date-time", nullable: true},
          updated_at: %Schema{type: :string, format: :"date-time", nullable: true}
        },
        required: [
          :id,
          :agent_uid,
          :owner_session_id,
          :resource_kind,
          :automation_job_id,
          :label,
          :definition_status,
          :status,
          :attempts,
          :attempt_id,
          :error,
          :scheduled_event_id,
          :started_at,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WorkflowActivityCounts do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "WorkflowActivityCounts",
        type: :object,
        properties: %{
          total: %Schema{type: :integer, minimum: 0},
          queued: %Schema{type: :integer, minimum: 0},
          running: %Schema{type: :integer, minimum: 0},
          sleeping: %Schema{type: :integer, minimum: 0},
          succeeded: %Schema{type: :integer, minimum: 0},
          failed: %Schema{type: :integer, minimum: 0},
          cancelled: %Schema{type: :integer, minimum: 0}
        },
        required: [:total, :queued, :running, :sleeping, :succeeded, :failed, :cancelled],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundActivityWorkflowCall do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BackgroundActivityWorkflowCall",
        type: :object,
        properties: %{
          id: %Schema{
            type: :integer,
            minimum: Ankole.ModelIntegerID.minimum(),
            maximum: Ankole.ModelIntegerID.maximum()
          },
          agent_uid: %Schema{type: :string},
          owner_session_id: %Schema{type: :string},
          resource_kind: %Schema{type: :string, enum: ["workflow_call"]},
          run_id: %Schema{
            type: :integer,
            minimum: Ankole.ModelIntegerID.minimum(),
            maximum: Ankole.ModelIntegerID.maximum()
          },
          run_status: %Schema{type: :string},
          run_title: %Schema{type: :string},
          task_session_id: %Schema{type: :string},
          label: %Schema{type: :string, nullable: true},
          status: %Schema{type: :string, enum: ["queued", "running", "sleeping"]},
          sleep_note: %Schema{type: :string, nullable: true},
          wake_kind: %Schema{
            type: :string,
            enum: ["sleep", "agent_capacity", nil],
            nullable: true
          },
          wake_at: %Schema{type: :string, format: :"date-time", nullable: true},
          attention: %Schema{type: :boolean},
          attempts: %Schema{type: :integer, minimum: 0},
          error_code: %Schema{type: :string, nullable: true},
          error_summary: %Schema{type: :string, nullable: true},
          run_error_code: %Schema{type: :string, nullable: true},
          run_error_summary: %Schema{type: :string, nullable: true},
          updated_at: %Schema{type: :string, format: :"date-time", nullable: true},
          run_counts: WorkflowActivityCounts
        },
        required: [
          :id,
          :agent_uid,
          :owner_session_id,
          :resource_kind,
          :run_id,
          :run_status,
          :run_title,
          :task_session_id,
          :label,
          :status,
          :sleep_note,
          :wake_kind,
          :wake_at,
          :attention,
          :attempts,
          :error_code,
          :error_summary,
          :run_error_code,
          :run_error_summary,
          :updated_at,
          :run_counts
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundActivityWorkflowRun do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BackgroundActivityWorkflowRun",
        type: :object,
        properties: %{
          id: %Schema{
            type: :integer,
            minimum: Ankole.ModelIntegerID.minimum(),
            maximum: Ankole.ModelIntegerID.maximum()
          },
          agent_uid: %Schema{type: :string},
          owner_session_id: %Schema{type: :string},
          resource_kind: %Schema{type: :string, enum: ["workflow_run"]},
          title: %Schema{type: :string},
          status: %Schema{type: :string},
          cleanup_pending: %Schema{type: :boolean},
          error_code: %Schema{type: :string, nullable: true},
          error_summary: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string, format: :"date-time", nullable: true},
          completed_at: %Schema{type: :string, format: :"date-time", nullable: true},
          updated_at: %Schema{type: :string, format: :"date-time", nullable: true},
          counts: WorkflowActivityCounts
        },
        required: [
          :id,
          :agent_uid,
          :owner_session_id,
          :resource_kind,
          :title,
          :status,
          :cleanup_pending,
          :error_code,
          :error_summary,
          :inserted_at,
          :completed_at,
          :updated_at,
          :counts
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundActivityJobsResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BackgroundActivityJobsResponse",
        type: :object,
        properties: %{
          observed_at: %Schema{type: :string, format: :"date-time"},
          jobs: %Schema{type: :array, items: BackgroundActivityJob},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:observed_at, :jobs, :next_cursor],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundActivityAutomationRunsResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BackgroundActivityAutomationRunsResponse",
        type: :object,
        properties: %{
          observed_at: %Schema{type: :string, format: :"date-time"},
          runs: %Schema{type: :array, items: BackgroundActivityAutomationRun},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:observed_at, :runs, :next_cursor],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule BackgroundActivityWorkflowResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "BackgroundActivityWorkflowResponse",
        type: :object,
        properties: %{
          observed_at: %Schema{type: :string, format: :"date-time"},
          live_calls: %Schema{type: :array, items: BackgroundActivityWorkflowCall},
          calls_next_cursor: %Schema{type: :string, nullable: true},
          runs: %Schema{type: :array, items: BackgroundActivityWorkflowRun},
          runs_next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:observed_at, :live_calls, :calls_next_cursor, :runs, :runs_next_cursor],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
