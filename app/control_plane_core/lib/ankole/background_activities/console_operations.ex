defmodule Ankole.BackgroundActivities.ConsoleOperations do
  @moduledoc "Typed Console operations that call the Ankole.BackgroundActivities owner."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.BackgroundActivities,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:agent_uid, :principal_key)
    allow(:console_jobs, resource: "site_console:background_agent_jobs", action: "read")
    allow(:console_workflow, resource: "site_console:agent:{agent_uid}:workflow", action: "read")

    allow(:console_automation_runs,
      resource: "site_console:agent:{agent_uid}:automation_jobs",
      action: "read"
    )
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("background_activities_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_jobs, :map do
      transaction?(false)

      constraints(
        fields: [
          jobs: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  agent_uid: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  attempts: [type: :integer, allow_nil?: false],
                  error_code: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  error_summary: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  id: [type: :integer, allow_nil?: false],
                  owner_session_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  queued_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  resource_kind: [
                    type: :atom,
                    constraints: [one_of: [:background_job]],
                    allow_nil?: false
                  ],
                  source_signal_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true]
                  ],
                  started_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  status: [
                    type: :atom,
                    constraints: [one_of: [:queued, :running, :waiting_on_user]],
                    allow_nil?: false
                  ],
                  title: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  updated_at: [type: :string, constraints: [trim?: false, allow_empty?: true]]
                ]
              ]
            ],
            allow_nil?: false
          ],
          next_cursor: [type: :string, constraints: [trim?: false, allow_empty?: true]],
          observed_at: [
            type: :string,
            constraints: [trim?: false, allow_empty?: true],
            allow_nil?: false
          ]
        ]
      )

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:limit, :integer, default: 25, constraints: [min: 1, max: 100])
      argument(:cursor, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.BackgroundActivities.ConsoleActions)
    end

    action :console_workflow, :map do
      transaction?(false)

      constraints(
        fields: [
          calls_next_cursor: [type: :string, constraints: [trim?: false, allow_empty?: true]],
          live_calls: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  agent_uid: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  attempts: [type: :integer, allow_nil?: false],
                  attention: [type: :boolean, allow_nil?: false],
                  error_code: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  error_summary: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  id: [type: :integer, allow_nil?: false],
                  label: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  owner_session_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  resource_kind: [
                    type: :atom,
                    constraints: [one_of: [:workflow_call]],
                    allow_nil?: false
                  ],
                  run_counts: [
                    type: Ankole.BackgroundActivities.ConsoleRunCounts,
                    allow_nil?: false
                  ],
                  run_error_code: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  run_error_summary: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true]
                  ],
                  run_id: [type: :integer, allow_nil?: false],
                  run_status: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  run_title: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  sleep_note: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  status: [
                    type: :atom,
                    constraints: [one_of: [:queued, :running, :sleeping]],
                    allow_nil?: false
                  ],
                  task_session_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  updated_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  wake_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  wake_kind: [
                    type: :atom,
                    constraints: [one_of: [:sleep, :agent_capacity, :null]]
                  ]
                ]
              ]
            ],
            allow_nil?: false
          ],
          observed_at: [
            type: :string,
            constraints: [trim?: false, allow_empty?: true],
            allow_nil?: false
          ],
          runs: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  agent_uid: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  cleanup_pending: [type: :boolean, allow_nil?: false],
                  completed_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  counts: [
                    type: Ankole.BackgroundActivities.ConsoleRunCounts,
                    allow_nil?: false
                  ],
                  error_code: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  error_summary: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  id: [type: :integer, allow_nil?: false],
                  inserted_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  owner_session_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  resource_kind: [
                    type: :atom,
                    constraints: [one_of: [:workflow_run]],
                    allow_nil?: false
                  ],
                  status: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  title: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  updated_at: [type: :string, constraints: [trim?: false, allow_empty?: true]]
                ]
              ]
            ],
            allow_nil?: false
          ],
          runs_next_cursor: [type: :string, constraints: [trim?: false, allow_empty?: true]]
        ]
      )

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:limit, :integer, default: 25, constraints: [min: 1, max: 100])
      argument(:calls_cursor, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:runs_cursor, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.BackgroundActivities.ConsoleActions)
    end

    action :console_automation_runs, :map do
      transaction?(false)

      constraints(
        fields: [
          next_cursor: [type: :string, constraints: [trim?: false, allow_empty?: true]],
          observed_at: [
            type: :string,
            constraints: [trim?: false, allow_empty?: true],
            allow_nil?: false
          ],
          runs: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  agent_uid: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  attempt_id: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  attempts: [type: :integer, allow_nil?: false],
                  automation_job_id: [type: :integer, allow_nil?: false],
                  definition_status: [
                    type: :atom,
                    constraints: [one_of: [:active, :cancelled]],
                    allow_nil?: false
                  ],
                  error: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  id: [type: :integer, allow_nil?: false],
                  inserted_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  label: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  owner_session_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  resource_kind: [
                    type: :atom,
                    constraints: [one_of: [:automation_run]],
                    allow_nil?: false
                  ],
                  scheduled_event_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true]
                  ],
                  started_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  status: [
                    type: :atom,
                    constraints: [one_of: [:queued, :running]],
                    allow_nil?: false
                  ],
                  updated_at: [type: :string, constraints: [trim?: false, allow_empty?: true]]
                ]
              ]
            ],
            allow_nil?: false
          ]
        ]
      )

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:limit, :integer, default: 25, constraints: [min: 1, max: 100])
      argument(:cursor, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.BackgroundActivities.ConsoleActions)
    end
  end
end
