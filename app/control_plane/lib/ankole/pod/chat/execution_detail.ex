defmodule Ankole.Pod.Chat.ExecutionDetail do
  @moduledoc "Structured snapshot and bounded timeline page for a room-linked execution."

  @task_counts [
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
  ]

  @question_option [
    fields: [
      label: [type: :string, allow_nil?: false],
      description: [type: :string]
    ]
  ]

  @pending_question [
    fields: [
      id: [type: :string, allow_nil?: false],
      header: [type: :string],
      question: [type: :string, allow_nil?: false],
      isOther: [type: :boolean],
      isSecret: [type: :boolean],
      options: [type: {:array, :map}, constraints: [items: @question_option]]
    ]
  ]

  @plan_step [
    fields: [
      step: [type: :string, allow_nil?: false],
      status: [type: :string, allow_nil?: false]
    ]
  ]

  @thread [
    fields: [
      id: [type: :string, allow_nil?: false],
      isLead: [type: :boolean, allow_nil?: false],
      status: [type: :string, allow_nil?: false],
      turnCount: [type: :integer, allow_nil?: false]
    ]
  ]

  @file_change [
    fields: [
      path: [type: :string, allow_nil?: false],
      kind: [type: :string, allow_nil?: false],
      diff: [type: :string, constraints: [trim?: false]]
    ]
  ]

  @item [
    fields: [
      id: [type: :string, allow_nil?: false],
      kind: [type: :string, allow_nil?: false],
      threadID: [type: :string],
      isLead: [type: :boolean],
      turnStatus: [type: :string],
      phase: [type: :string],
      text: [type: :string, constraints: [trim?: false]],
      toolKind: [type: :string],
      tool: [type: :string],
      title: [type: :string, constraints: [trim?: false]],
      status: [type: :string],
      durationMs: [type: :integer],
      skillName: [type: :string],
      command: [
        type: :map,
        constraints: [
          fields: [
            command: [type: :string, constraints: [trim?: false]],
            cwd: [type: :string],
            output: [type: :string, constraints: [trim?: false]],
            exitCode: [type: :integer]
          ]
        ]
      ],
      files: [type: {:array, :map}, constraints: [items: @file_change]],
      collab: [
        type: :map,
        constraints: [
          fields: [
            action: [type: :string, allow_nil?: false],
            prompt: [type: :string, constraints: [trim?: false]],
            receiverThreadIDs: [type: {:array, :string}],
            agentSummary: [type: :string, constraints: [trim?: false]]
          ]
        ]
      ],
      input: [type: :string, constraints: [trim?: false]],
      output: [type: :string, constraints: [trim?: false]],
      error: [type: :string, constraints: [trim?: false]],
      callSeq: [type: :integer],
      attempts: [type: :integer],
      sleepNote: [type: :string, constraints: [trim?: false]],
      attention: [type: :boolean]
    ]
  ]

  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        id: [type: :string, allow_nil?: false],
        kind: [
          type: :atom,
          allow_nil?: false,
          constraints: [one_of: [:background_agent_job, :workflow]]
        ],
        title: [type: :string, allow_nil?: false],
        agentUID: [type: Ankole.Ash.Types.PrincipalKey, allow_nil?: false],
        status: [type: :string, allow_nil?: false],
        task: [type: :string, constraints: [trim?: false]],
        createdAt: [type: :utc_datetime_usec, allow_nil?: false],
        startedAt: [type: :utc_datetime_usec],
        completedAt: [type: :utc_datetime_usec],
        updatedAt: [type: :utc_datetime_usec, allow_nil?: false],
        stoppable: [type: :boolean, allow_nil?: false],
        canMessage: [type: :boolean, allow_nil?: false],
        continuedFromJobID: [type: :string],
        successorJobID: [type: :string],
        outcomeText: [type: :string, constraints: [trim?: false]],
        errorText: [type: :string, constraints: [trim?: false]],
        stepCount: [type: :integer, allow_nil?: false],
        pendingQuestions: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [items: @pending_question]
        ],
        plan: [
          type: :map,
          constraints: [
            fields: [
              explanation: [type: :string, constraints: [trim?: false]],
              steps: [type: {:array, :map}, allow_nil?: false, constraints: [items: @plan_step]]
            ]
          ]
        ],
        threads: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [items: @thread]
        ],
        workflowCounts: @task_counts,
        items: [
          type: {:array, :map},
          allow_nil?: false,
          constraints: [items: @item]
        ],
        nextCursor: [type: :string]
      ]
    ]
end
