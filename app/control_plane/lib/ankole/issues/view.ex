defmodule Ankole.Issues.View do
  @moduledoc """
  A work item: a room that has an Issue, or a room in which a Background Agent
  Job or Workflow is live.

  `status` follows the room (`waiting`, `working`) and otherwise the Issue
  (`todo`, `review`, `done`). `tracked` tells that the room has an Issue, and
  `description` is the request of an Issue that has not started. `runs` are the
  room's live runs, in the shape of a room's linked runs.
  """

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: Ankole.Ash.Types.UUIDv7, allow_nil?: false],
        title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true]],
        status: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:todo, :working, :waiting, :review, :done]]
        ],
        tracked: [type: :boolean, allow_nil?: false],
        description: [type: :string, constraints: [allow_empty?: true, trim?: false]],
        agent: [
          type: :map,
          constraints: [
            fields: [
              uid: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
              name: [type: :string, allow_nil?: false, constraints: [allow_empty?: true]]
            ]
          ]
        ],
        runs: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [
            items: [
              fields: [
                id: [type: :string, allow_nil?: false],
                kind: [
                  type: :atom,
                  allow_nil?: false,
                  constraints: [one_of: [:background_agent_job, :workflow]]
                ],
                title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true]],
                agentUID: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
                status: [type: :string, allow_nil?: false],
                stoppable: [type: :boolean],
                summary: [type: :string, constraints: [trim?: false]],
                stepCount: [type: :integer],
                planCompleted: [type: :integer],
                planTotal: [type: :integer],
                taskCounts: [
                  type: :map,
                  constraints: [
                    fields: [
                      total: [type: :integer, allow_nil?: false],
                      completed: [type: :integer, allow_nil?: false],
                      running: [type: :integer, allow_nil?: false],
                      queued: [type: :integer, allow_nil?: false],
                      sleeping: [type: :integer, allow_nil?: false],
                      failed: [type: :integer, allow_nil?: false]
                    ]
                  ]
                ],
                startedAt: [type: :utc_datetime_usec],
                completedAt: [type: :utc_datetime_usec],
                createdAt: [type: :utc_datetime_usec, allow_nil?: false],
                updatedAt: [type: :utc_datetime_usec, allow_nil?: false]
              ]
            ]
          ]
        ],
        lastActivityAt: [type: :utc_datetime_usec, allow_nil?: false]
      ]
    ]
end
