defmodule Ankole.AgentWorkers.Providers.ConsoleOperations do
  @moduledoc "Worker provider catalog and connection checks for site operators."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.AgentWorkers.Providers,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("worker_provider_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_kinds, :map do
      transaction?(false)

      constraints(
        fields: [
          worker_provider_kinds: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  kind: [type: :string, allow_nil?: false],
                  example: [type: :string, allow_nil?: false],
                  credentials: [
                    type: Ankole.AgentWorkers.ProviderKind.CredentialFields,
                    allow_nil?: false
                  ]
                ]
              ]
            ]
          ]
        ]
      )

      run(Ankole.AgentWorkers.Providers.ConsoleActions)
    end

    action :console_check, :map do
      transaction?(false)
      constraints(fields: [available: [type: :boolean, allow_nil?: false]])
      argument(:provider_id, :string, allow_nil?: false, constraints: [trim?: false])
      run(Ankole.AgentWorkers.Providers.ConsoleActions)
    end
  end
end
