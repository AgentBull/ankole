defmodule Ankole.Sessions.ConsoleOperations do
  @moduledoc "Typed Console operations that call the Ankole.Sessions owner."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Sessions,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:agent_uid, :principal_key)
    allow(:console_sessions, resource: "site_console:agent:{agent_uid}:sessions", action: "read")
    allow(:console_standing_orders, resource: "site_console:conversations", action: "read")
    allow(:console_put_standing_orders, resource: "site_console:conversations", action: "update")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("sessions_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_sessions, :map do
      transaction?(false)

      constraints(
        fields: [
          sessions: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  kind: [type: :atom, constraints: [one_of: [:job, :session]], allow_nil?: false],
                  last_activity_at: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true]
                  ],
                  session_id: [
                    type: :string,
                    constraints: [trim?: false, allow_empty?: true],
                    allow_nil?: false
                  ],
                  status: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                  title: [type: :string, constraints: [trim?: false, allow_empty?: true]]
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

      run(Ankole.Sessions.ConsoleActions)
    end

    action :console_standing_orders, :map do
      transaction?(false)

      constraints(
        fields: [
          standing_orders: [
            type: :map,
            constraints: [
              fields: [
                conversation_id: [
                  type: :string,
                  constraints: [trim?: false, allow_empty?: true],
                  allow_nil?: false
                ],
                orders: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                set_by: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                title: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                updated_at: [type: :string, constraints: [trim?: false, allow_empty?: true]]
              ]
            ],
            allow_nil?: false
          ]
        ]
      )

      argument(:conversation_id, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      run(Ankole.Sessions.ConsoleActions)
    end

    action :console_put_standing_orders, :map do
      transaction?(false)

      constraints(
        fields: [
          standing_orders: [
            type: :map,
            constraints: [
              fields: [
                conversation_id: [
                  type: :string,
                  constraints: [trim?: false, allow_empty?: true],
                  allow_nil?: false
                ],
                orders: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                set_by: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                title: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                updated_at: [type: :string, constraints: [trim?: false, allow_empty?: true]]
              ]
            ],
            allow_nil?: false
          ]
        ]
      )

      argument(:conversation_id, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:orders, :string, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.Sessions.ConsoleActions)
    end
  end
end
