defmodule Ankole.Pod.JobsBoard.View do
  @moduledoc """
  JSON:API card shape for one entry on the Pod `/jobs` board.
  """

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: :string, allow_nil?: false],
        rawID: [type: :string, allow_nil?: false],
        kind: [
          type: :atom,
          allow_nil?: false,
          constraints: [
            one_of: [:background_agent_job, :workflow, :cron, :automation_job, :checkback]
          ]
        ],
        cardType: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:one_off, :routine]]
        ],
        column: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:scheduled, :running, :completed]]
        ],
        status: [type: :string, allow_nil?: false],
        attention: [type: :boolean, allow_nil?: false],
        attentionReason: [type: :string],
        title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false]],
        summary: [type: :string, constraints: [allow_empty?: true, trim?: false]],
        agentUID: [type: Ankole.Ash.Types.PrincipalKey],
        agentName: [type: :string, constraints: [allow_empty?: true, trim?: false]],
        conversationID: [type: Ankole.Ash.Types.UUIDv7],
        conversationTitle: [type: :string, constraints: [allow_empty?: true, trim?: false]],
        pageID: [type: Ankole.Ash.Types.UUIDv7],
        pageTitle: [type: :string, constraints: [allow_empty?: true, trim?: false]],
        manageable: [type: :boolean, allow_nil?: false],
        stoppable: [type: :boolean, allow_nil?: false],
        canMessage: [type: :boolean, allow_nil?: false],
        stepCount: [type: :integer, allow_nil?: false],
        planCompleted: [type: :integer],
        planTotal: [type: :integer],
        chainLength: [type: :integer, allow_nil?: false],
        activeExecutionKind: [
          type: :atom,
          constraints: [one_of: [:background_agent_job, :workflow]]
        ],
        activeExecutionID: [type: :string],
        schedule: [type: :map],
        timezone: [type: :string],
        nextRunAt: [type: :utc_datetime_usec],
        lastRunAt: [type: :utc_datetime_usec],
        lastRunStatus: [type: :string],
        triggerSummary: [type: :string, constraints: [allow_empty?: true, trim?: false]],
        createdAt: [type: :utc_datetime_usec, allow_nil?: false],
        updatedAt: [type: :utc_datetime_usec, allow_nil?: false]
      ]
    ]
end
