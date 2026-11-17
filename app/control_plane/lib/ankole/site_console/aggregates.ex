defmodule Ankole.SiteConsole.Aggregates do
  @moduledoc "Typed site-wide cross-tenant Console views with cursor pagination."
  use Ankole.Ash.OperationResource,
    tenancy: :site,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.SiteConsole,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Ash.Types.{JSONMap, UUIDv7}

  authz do
    scope(:site_console)
    allow(:overview, resource: "site_console:tenants", action: "read")
    allow(:agents, resource: "site_console:agents", action: "read")
    allow(:workers, resource: "site_console:agent_workers", action: "read")
    allow(:principals, resource: "site_console:principals", action: "read")
    allow(:signal_bindings, resource: "site_console:signal_bindings", action: "read")
    allow(:schedules, resource: "site_console:schedules", action: "read")
    allow(:background_agent_jobs, resource: "site_console:background_agent_jobs", action: "read")
    allow(:ai_usage, resource: "site_console:ai_gateway_usage", action: "read")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("site_console_aggregate")
    derive_filter?(false)
    derive_sort?(false)
  end

  @tenant_meta [
    tenant_id: [type: UUIDv7, allow_nil?: false],
    tenant_slug: [type: :string, allow_nil?: false],
    tenant_display_name: [type: :string, allow_nil?: false]
  ]

  @agent_item @tenant_meta ++
                [
                  uid: [type: :string, allow_nil?: false],
                  display_name: [type: :string],
                  type: [type: :string, allow_nil?: false],
                  status: [type: :string, allow_nil?: false],
                  role: [type: :string, allow_nil?: false],
                  owner_principal_uid: [type: :string],
                  worker_provider_id: [type: :string],
                  worker_state: [type: :string]
                ]

  @worker_item @tenant_meta ++
                 [
                   agent_uid: [type: :string, allow_nil?: false],
                   provider_id: [type: :string],
                   state: [type: :string, allow_nil?: false],
                   generation: [type: :string],
                   image: [type: :string],
                   capacity: [type: JSONMap, allow_nil?: false],
                   load: [type: JSONMap, allow_nil?: false],
                   last_worker_heartbeat_at: [type: :string],
                   state_changed_at: [type: :string, allow_nil?: false],
                   drain_reason: [type: :string],
                   last_error: [type: :string]
                 ]

  @principal_item @tenant_meta ++
                    [
                      uid: [type: :string, allow_nil?: false],
                      type: [type: :string, allow_nil?: false],
                      status: [type: :string, allow_nil?: false],
                      membership: [type: :string],
                      display_name: [type: :string],
                      email: [type: :string],
                      service_kind: [type: :string]
                    ]

  @signal_binding_item @tenant_meta ++
                         [
                           id: [type: UUIDv7, allow_nil?: false],
                           name: [type: :string, allow_nil?: false],
                           adapter: [type: :string, allow_nil?: false],
                           routing_mode: [type: :string, allow_nil?: false],
                           agent_uid: [type: :string],
                           enabled: [type: :boolean, allow_nil?: false],
                           external_bot_policy: [type: :string, allow_nil?: false],
                           unavailable_reason: [type: :string]
                         ]

  @schedule_item @tenant_meta ++
                   [
                     id: [type: UUIDv7, allow_nil?: false],
                     agent_uid: [type: :string, allow_nil?: false],
                     name: [type: :string, allow_nil?: false],
                     status: [type: :string, allow_nil?: false],
                     timezone: [type: :string, allow_nil?: false],
                     next_fire_at: [type: :string],
                     last_fire_at: [type: :string]
                   ]

  @job_item @tenant_meta ++
              [
                id: [type: :integer, allow_nil?: false],
                agent_uid: [type: :string, allow_nil?: false],
                title: [type: :string, allow_nil?: false],
                status: [type: :string, allow_nil?: false],
                attempts: [type: :integer, allow_nil?: false],
                queued_at: [type: :string],
                started_at: [type: :string],
                completed_at: [type: :string]
              ]

  @usage_tenant_item @tenant_meta ++
                       [
                         rounds: [type: :integer, allow_nil?: false],
                         input_tokens: [type: :integer, allow_nil?: false],
                         output_tokens: [type: :integer, allow_nil?: false],
                         cached_input_tokens: [type: :integer, allow_nil?: false],
                         reasoning_tokens: [type: :integer, allow_nil?: false]
                       ]

  actions do
    action :overview, :map do
      transaction?(false)

      constraints(
        fields: [
          active_tenants: [type: :integer, allow_nil?: false],
          suspended_tenants: [type: :integer, allow_nil?: false],
          active_agents: [type: :integer, allow_nil?: false],
          disabled_agents: [type: :integer, allow_nil?: false],
          ready_workers: [type: :integer, allow_nil?: false],
          starting_workers: [type: :integer, allow_nil?: false],
          unhealthy_workers: [type: :integer, allow_nil?: false],
          running_background_jobs: [type: :integer, allow_nil?: false]
        ]
      )

      run(__MODULE__.Actions)
    end

    for {action_name, item_fields} <- [
          agents: @agent_item,
          workers: @worker_item,
          principals: @principal_item,
          signal_bindings: @signal_binding_item,
          schedules: @schedule_item,
          background_agent_jobs: @job_item
        ] do
      action action_name, :map do
        transaction?(false)
        argument(:q, :string, default: "", constraints: [allow_empty?: true])
        argument(:cursor, :string, default: "", constraints: [allow_empty?: true])
        argument(:limit, :integer, default: 50, constraints: [min: 1, max: 100])

        if action_name == :principals do
          argument(:include_disabled, :boolean, default: false)
          argument(:include_system, :boolean, default: false)
        end

        if action_name == :signal_bindings do
          argument(:include_disabled, :boolean, default: false)
        end

        if action_name in [:agents, :workers, :schedules, :background_agent_jobs] do
          argument(:status, :string, default: "", constraints: [allow_empty?: true])
        end

        constraints(
          fields: [
            items: [
              type: {:array, :map},
              allow_nil?: false,
              constraints: [items: [fields: item_fields]]
            ],
            next_cursor: [type: :string]
          ]
        )

        run(__MODULE__.Actions)
      end
    end

    action :ai_usage, :map do
      transaction?(false)
      argument(:days, :integer, allow_nil?: false, default: 7, constraints: [min: 1, max: 90])

      constraints(
        fields: [
          window_started_at: [type: :string, allow_nil?: false],
          total_rounds: [type: :integer, allow_nil?: false],
          total_input_tokens: [type: :integer, allow_nil?: false],
          total_output_tokens: [type: :integer, allow_nil?: false],
          by_tenant: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @usage_tenant_item]]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end
  end
end
