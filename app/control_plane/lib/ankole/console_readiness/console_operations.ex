defmodule Ankole.ConsoleReadiness.ConsoleOperations do
  @moduledoc "Typed Console operations that call the Ankole.ConsoleReadiness owner."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.ConsoleReadiness,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_snapshot, resource: "site_console:console_readiness", action: "read")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("console_readiness_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_snapshot, :map do
      transaction?(false)

      constraints(
        fields: [
          agent: [
            type: :map,
            constraints: [
              fields: [
                complete: [type: :boolean, allow_nil?: false],
                display_name: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                uid: [type: :string, constraints: [trim?: false, allow_empty?: true]]
              ]
            ],
            allow_nil?: false
          ],
          completed_core_steps: [type: :integer, allow_nil?: false],
          model_profiles: [
            type: :map,
            constraints: [
              fields: [
                agent_uid: [type: :string, constraints: [trim?: false, allow_empty?: true]],
                complete: [type: :boolean, allow_nil?: false],
                missing_profiles: [
                  type: {:array, :string},
                  constraints: [items: [trim?: false, allow_empty?: true]],
                  allow_nil?: false
                ]
              ]
            ],
            allow_nil?: false
          ],
          provider: [
            type: :map,
            constraints: [
              fields: [
                complete: [type: :boolean, allow_nil?: false],
                provider_id: [type: :string, constraints: [trim?: false, allow_empty?: true]]
              ]
            ],
            allow_nil?: false
          ],
          ready: [type: :boolean, allow_nil?: false],
          signal_route: [
            type: :map,
            constraints: [fields: [complete: [type: :boolean, allow_nil?: false]]],
            allow_nil?: false
          ],
          total_core_steps: [type: :integer, allow_nil?: false],
          worker: [
            type: :map,
            constraints: [
              fields: [
                complete: [type: :boolean, allow_nil?: false],
                ready_count: [type: :integer, allow_nil?: false]
              ]
            ],
            allow_nil?: false
          ]
        ]
      )

      run(Ankole.ConsoleReadiness.ConsoleActions)
    end
  end
end
