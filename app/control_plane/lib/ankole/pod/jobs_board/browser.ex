defmodule Ankole.Pod.JobsBoard.Browser do
  @moduledoc """
  Stateless JSON:API operation resource for the Pod `/jobs` board (`/api/v2/pod/jobs`).
  """

  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Ash.Types.{JSONMap, PrincipalKey, UUIDv7}
  alias Ankole.Pod.APIError
  alias Ankole.Pod.Chat.ExecutionDetail
  alias Ankole.Pod.JobsBoard
  alias Ankole.Pod.JobsBoard.View

  @candidate_agent [
    uid: [type: PrincipalKey, allow_nil?: false],
    displayName: [type: :string, allow_nil?: false],
    agentType: [type: :string, allow_nil?: false],
    avatarURL: [type: :string],
    canRunBackgroundJob: [type: :boolean, allow_nil?: false]
  ]

  @event_trigger_input [
    configRef: [type: :string, allow_nil?: false],
    name: [type: :string],
    filters: [type: JSONMap],
    watchedFieldIDs: [type: {:array, UUIDv7}],
    coalesce: [type: JSONMap]
  ]

  @routine_run [
    id: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    trigger: [type: :string],
    startedAt: [type: :utc_datetime_usec],
    finishedAt: [type: :utc_datetime_usec],
    summary: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    error: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    deliveryWarning: [type: :boolean]
  ]

  @child_execution [
    id: [type: :string, allow_nil?: false],
    kind: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:background_agent_job, :workflow]]
    ],
    title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false]],
    status: [type: :string, allow_nil?: false],
    summary: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    startedAt: [type: :utc_datetime_usec],
    completedAt: [type: :utc_datetime_usec],
    createdAt: [type: :utc_datetime_usec, allow_nil?: false]
  ]

  authz do
    scope(:pod)
    allow(:summary, check: :guardrail)
    allow(:list, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:routine_detail, check: :guardrail)
    allow(:update_routine, check: :guardrail)
    allow(:change_routine, check: :guardrail)
    allow(:execution, check: :guardrail)
    allow(:stop_execution, check: :guardrail)
    allow(:message_execution, check: :guardrail)
  end

  json_api do
    type("pod_job_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :summary, :map do
      transaction?(false)

      constraints(
        fields: [
          scheduledCount: [type: :integer, allow_nil?: false],
          runningCount: [type: :integer, allow_nil?: false],
          attentionCount: [type: :integer, allow_nil?: false]
        ]
      )

      run(fn _input, context ->
        JobsBoard.summary(context.actor) |> APIError.result()
      end)
    end

    action :list, :map do
      transaction?(false)

      constraints(
        fields: [
          items: [type: {:array, View}, allow_nil?: false],
          agents: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @candidate_agent]]
          ]
        ]
      )

      run(fn _input, context ->
        JobsBoard.list(context.actor) |> APIError.result()
      end)
    end

    action :create, View do
      transaction?(false)

      argument(:mode, :atom,
        allow_nil?: false,
        constraints: [one_of: [:one_off, :cron]]
      )

      argument(:agentUID, PrincipalKey, allow_nil?: false)

      argument(:title, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]
      )

      argument(:task, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 20_000, trim?: false]
      )

      argument(:requestID, UUIDv7, allow_nil?: false)
      argument(:conversationID, UUIDv7)
      argument(:runnerID, UUIDv7)

      argument(:repeat, :map,
        constraints: [
          fields: [
            expression: [type: :string, allow_nil?: false],
            timezone: [type: :string, allow_nil?: false]
          ]
        ]
      )

      argument(:quietSuccess, :boolean)
      argument(:runNow, :boolean)

      argument(:eventTriggers, {:array, :map},
        constraints: [items: [fields: @event_trigger_input]]
      )

      run(fn input, context ->
        args = input.arguments

        JobsBoard.create(context.actor, %{
          mode: args.mode,
          agent_uid: args.agentUID,
          title: args.title,
          task: args.task,
          request_id: args.requestID,
          conversation_id: args[:conversationID],
          runner_id: args[:runnerID],
          repeat: args[:repeat],
          event_triggers: args[:eventTriggers],
          quiet_success: args[:quietSuccess],
          run_now: args[:runNow]
        })
        |> APIError.result()
      end)
    end

    action :update_routine, View do
      transaction?(false)

      argument(:raw_id, :string, allow_nil?: false)

      argument(:title, :string, constraints: [min_length: 1, max_length: 200])

      argument(:task, :string, constraints: [min_length: 1, max_length: 20_000, trim?: false])

      argument(:conversationID, UUIDv7)

      argument(:repeat, :map,
        constraints: [
          fields: [
            expression: [type: :string, allow_nil?: false],
            timezone: [type: :string, allow_nil?: false]
          ]
        ]
      )

      argument(:removeSchedule, :boolean)
      argument(:quietSuccess, :boolean)

      run(fn input, context ->
        args = input.arguments

        attrs =
          %{}
          |> then(&if(Map.has_key?(args, :title), do: Map.put(&1, :title, args.title), else: &1))
          |> then(&if(Map.has_key?(args, :task), do: Map.put(&1, :task, args.task), else: &1))
          |> then(
            &if(Map.has_key?(args, :conversationID),
              do: Map.put(&1, :conversation_id, args.conversationID),
              else: &1
            )
          )
          |> then(
            &if(Map.has_key?(args, :repeat), do: Map.put(&1, :repeat, args.repeat), else: &1)
          )
          |> then(
            &if(Map.has_key?(args, :removeSchedule),
              do: Map.put(&1, :remove_schedule, args.removeSchedule),
              else: &1
            )
          )
          |> then(
            &if(Map.has_key?(args, :quietSuccess),
              do: Map.put(&1, :quiet_success, args.quietSuccess),
              else: &1
            )
          )

        JobsBoard.update_routine(context.actor, args.raw_id, attrs) |> APIError.result()
      end)
    end

    action :routine_detail, :map do
      transaction?(false)

      argument(:kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:cron, :automation_job, :checkback]]
      )

      argument(:raw_id, :string, allow_nil?: false)

      constraints(
        fields: [
          item: [type: View, allow_nil?: false],
          instructions: [
            type: :string,
            allow_nil?: false,
            constraints: [allow_empty?: true, trim?: false]
          ],
          quietSuccess: [type: :boolean],
          unavailableReason: [type: :string, constraints: [allow_empty?: true, trim?: false]],
          runs: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @routine_run]]
          ],
          childExecutions: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @child_execution]]
          ]
        ]
      )

      run(fn input, context ->
        args = input.arguments
        JobsBoard.routine_detail(context.actor, args.kind, args.raw_id) |> APIError.result()
      end)
    end

    action :change_routine, :map do
      transaction?(false)

      argument(:kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:cron, :checkback]]
      )

      argument(:raw_id, :string, allow_nil?: false)

      argument(:action, :atom,
        allow_nil?: false,
        constraints: [one_of: [:pause, :resume, :run, :remove, :cancel]]
      )

      constraints(
        fields: [
          id: [type: :string, allow_nil?: false],
          action: [type: :string, allow_nil?: false]
        ]
      )

      run(fn input, context ->
        args = input.arguments

        JobsBoard.change_routine(context.actor, args.kind, args.raw_id, args.action)
        |> APIError.result()
      end)
    end

    action :execution, ExecutionDetail do
      transaction?(false)

      argument(:kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:background_agent_job, :workflow]]
      )

      argument(:run_id, :integer,
        allow_nil?: false,
        constraints: [min: Ankole.ModelIntegerID.minimum(), max: Ankole.ModelIntegerID.maximum()]
      )

      argument(:cursor, :string)

      run(fn input, context ->
        args = input.arguments

        JobsBoard.execution_detail(context.actor, args.kind, args.run_id, args[:cursor])
        |> APIError.result()
      end)
    end

    action :stop_execution, :map do
      transaction?(false)

      argument(:kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:background_agent_job, :workflow]]
      )

      argument(:run_id, :integer,
        allow_nil?: false,
        constraints: [min: Ankole.ModelIntegerID.minimum(), max: Ankole.ModelIntegerID.maximum()]
      )

      constraints(
        fields: [
          runID: [type: :string, allow_nil?: false],
          status: [type: :string, allow_nil?: false]
        ]
      )

      run(fn input, context ->
        args = input.arguments
        JobsBoard.stop_execution(context.actor, args.kind, args.run_id) |> APIError.result()
      end)
    end

    action :message_execution, :map do
      transaction?(false)

      argument(:run_id, :integer,
        allow_nil?: false,
        constraints: [min: Ankole.ModelIntegerID.minimum(), max: Ankole.ModelIntegerID.maximum()]
      )

      argument(:requestID, UUIDv7, allow_nil?: false)
      argument(:text, :string, allow_nil?: false, constraints: [trim?: false])

      constraints(
        fields: [
          runID: [type: :string, allow_nil?: false],
          status: [type: :string, allow_nil?: false],
          respawned: [type: :boolean, allow_nil?: false]
        ]
      )

      run(fn input, context ->
        args = input.arguments

        JobsBoard.message_execution(context.actor, args.run_id, args.requestID, args.text)
        |> APIError.result()
      end)
    end
  end
end
