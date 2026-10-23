defmodule Ankole.AgentWorkers.WorkerEnv.SiteOperations do
  @moduledoc "Operator shell variable operations for the site Console."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.AgentWorkers.Providers,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("site_worker_env_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_list, :map do
      transaction?(false)

      constraints(
        fields: [
          worker_envs: [
            type: {:array, Ankole.AgentWorkers.WorkerEnv.ConsoleItem},
            allow_nil?: false
          ]
        ]
      )

      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :global})
    end

    action :console_put, :map do
      transaction?(false)

      constraints(
        fields: [worker_env: [type: Ankole.AgentWorkers.WorkerEnv.ConsoleItem, allow_nil?: false]]
      )

      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:value, :string, sensitive?: true, constraints: [trim?: false, allow_empty?: true])
      argument(:secret, :boolean)
      argument(:description, :string, constraints: [trim?: false, allow_empty?: true])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :global})
    end

    action :console_delete, :map do
      transaction?(false)

      constraints(
        fields: [worker_env: [type: Ankole.AgentWorkers.WorkerEnv.ConsoleItem, allow_nil?: false]]
      )

      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :global})
    end

    action :console_decrypt, :map do
      transaction?(false)

      constraints(
        fields: [
          decrypted_value: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                name: [type: :string, allow_nil?: false],
                value: [
                  type: :string,
                  allow_nil?: false,
                  constraints: [trim?: false, allow_empty?: true]
                ]
              ]
            ]
          ]
        ]
      )

      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :global})
    end
  end
end
