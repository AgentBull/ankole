defmodule Ankole.BackgroundAgentJobs.ConsoleOperations do
  @moduledoc "Typed Console operations that call the Ankole.BackgroundAgentJobs owner."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.BackgroundAgentJobs,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_health, resource: "site_console:background_agent_jobs", action: "read")
    allow(:console_turns, resource: "site_console:background_agent_jobs", action: "read")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("background_agent_jobs_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_health, :map do
      transaction?(false)

      constraints(
        fields: [
          agents_at_running_cap: [type: :integer, allow_nil?: false],
          claims_24h: [type: :integer, allow_nil?: false],
          dead_letter_notices_24h: [type: :integer, allow_nil?: false],
          execution_failures_24h: [type: :integer, allow_nil?: false],
          max_running_per_agent: [type: :integer, allow_nil?: false],
          oldest_queued_seconds: [type: :integer],
          queued_behind_running_cap: [type: :integer, allow_nil?: false],
          queued_count: [type: :integer, allow_nil?: false],
          running_count: [type: :integer, allow_nil?: false],
          succeeded_24h: [type: :integer, allow_nil?: false],
          successor_seeded_24h: [type: :integer, allow_nil?: false],
          wakeups_24h: [type: :integer, allow_nil?: false],
          window_seconds: [type: :integer, allow_nil?: false]
        ]
      )

      run(Ankole.BackgroundAgentJobs.ConsoleActions)
    end

    action :console_turns, :map do
      transaction?(false)

      constraints(
        fields: [
          next_cursor: [type: :string, constraints: [trim?: false, allow_empty?: true]],
          turns: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  attempt: [type: :integer, allow_nil?: false],
                  completed_at: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  error: [type: Ankole.Ash.Types.JSONMap, allow_nil?: false],
                  id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  inserted_at: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  kind: [
                    type: :atom,
                    constraints: [one_of: [:agent, :compaction]],
                    allow_nil?: false
                  ],
                  progress: [
                    type: :map,
                    constraints: [
                      fields: [
                        active_item: [
                          type: :map,
                          constraints: [
                            fields: [
                              id: [
                                type: :string,
                                constraints: [trim?: false, allow_empty?: true],
                                allow_nil?: false
                              ],
                              name: [
                                type: :string,
                                constraints: [trim?: false, allow_empty?: true],
                                allow_nil?: false
                              ],
                              namespace: [
                                type: :string,
                                constraints: [trim?: false, allow_empty?: true]
                              ]
                            ]
                          ]
                        ],
                        completed_items: [type: :integer, allow_nil?: false],
                        files_changed: [
                          type: {:array, :string},
                          constraints: [items: [trim?: false, allow_empty?: true]],
                          allow_nil?: false
                        ],
                        plan: [
                          type: :map,
                          constraints: [
                            fields: [
                              explanation: [
                                type: :string,
                                constraints: [trim?: false, allow_empty?: true]
                              ],
                              steps: [
                                type: {:array, :map},
                                constraints: [
                                  items: [
                                    fields: [
                                      status: [
                                        type: :atom,
                                        constraints: [
                                          one_of: [:pending, :in_progress, :completed]
                                        ],
                                        allow_nil?: false
                                      ],
                                      step: [
                                        type: :string,
                                        constraints: [trim?: false, allow_empty?: true],
                                        allow_nil?: false
                                      ]
                                    ]
                                  ]
                                ],
                                allow_nil?: false
                              ]
                            ]
                          ]
                        ],
                        tool_calls: [type: :integer, allow_nil?: false],
                        tool_execution_mechanisms: [
                          type: {:array, :map},
                          constraints: [
                            items: [
                              fields: [
                                calls: [type: :integer, allow_nil?: false],
                                execution_mechanism: [
                                  type: :atom,
                                  constraints: [one_of: [:local_dynamic, :provider_hosted]],
                                  allow_nil?: false
                                ],
                                name: [
                                  type: :string,
                                  constraints: [trim?: false, allow_empty?: true],
                                  allow_nil?: false
                                ],
                                namespace: [
                                  type: :string,
                                  constraints: [trim?: false, allow_empty?: true]
                                ]
                              ]
                            ]
                          ]
                        ],
                        tools_used: [
                          type: {:array, :map},
                          constraints: [
                            items: [
                              fields: [
                                calls: [type: :integer, allow_nil?: false],
                                name: [
                                  type: :string,
                                  constraints: [trim?: false, allow_empty?: true],
                                  allow_nil?: false
                                ],
                                namespace: [
                                  type: :string,
                                  constraints: [trim?: false, allow_empty?: true]
                                ]
                              ]
                            ]
                          ],
                          allow_nil?: false
                        ]
                      ]
                    ],
                    allow_nil?: false
                  ],
                  revision: [type: :integer, allow_nil?: false],
                  runtime_thread_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  runtime_turn_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  started_at: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  status: [
                    type: :atom,
                    constraints: [one_of: [:in_progress, :completed, :failed, :interrupted]],
                    allow_nil?: false
                  ],
                  trajectory: [
                    type: :map,
                    constraints: [
                      fields: [
                        format: [
                          type: :atom,
                          constraints: [one_of: [:ankole_chatml]],
                          allow_nil?: false
                        ],
                        messages: [
                          type: {:array, Ankole.BackgroundAgentJobs.ConsoleMessage},
                          allow_nil?: false
                        ],
                        metadata: [
                          type: :map,
                          constraints: [
                            fields: [
                              content_truncated: [type: :boolean],
                              redacted: [type: :boolean]
                            ]
                          ]
                        ],
                        version: [type: :integer, allow_nil?: false]
                      ]
                    ],
                    allow_nil?: false
                  ],
                  updated_at: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  usage: [
                    type: :map,
                    constraints: [
                      fields: [
                        last_model_call: [
                          type: Ankole.BackgroundAgentJobs.ConsoleTokenUsage,
                          allow_nil?: false
                        ],
                        model_context_window: [type: :integer],
                        thread_total: [
                          type: Ankole.BackgroundAgentJobs.ConsoleTokenUsage,
                          allow_nil?: false
                        ]
                      ]
                    ]
                  ]
                ]
              ]
            ],
            allow_nil?: false
          ]
        ]
      )

      argument(:job_id, :integer, allow_nil?: false)
      argument(:cursor, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.BackgroundAgentJobs.ConsoleActions)
    end
  end
end
