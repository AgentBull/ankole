defmodule Ankole.AgentWorkers.WorkerEnv.ConsoleOperations do
  @moduledoc "Operator shell variable operations for the tenant and Agent Console."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.AgentWorkers,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:name, :string)
    resolve_param(:agent_uid, :principal_key)
    allow(:console_list, resource: "site_console:worker_envs", action: "read")
    allow(:console_put, resource: "site_console:worker_env:{name}", action: "update")
    allow(:console_delete, resource: "site_console:worker_env:{name}", action: "reset")
    allow(:console_decrypt, resource: "site_console:worker_env:{name}", action: "decrypt")

    allow(:console_list_for_agent,
      resource: "site_console:agent:{agent_uid}:worker_envs",
      action: "read"
    )

    allow(:console_put_for_agent,
      resource: "site_console:agent:{agent_uid}:worker_env:{name}",
      action: "update"
    )

    allow(:console_delete_for_agent,
      resource: "site_console:agent:{agent_uid}:worker_env:{name}",
      action: "reset"
    )

    allow(:console_decrypt_for_agent,
      resource: "site_console:agent:{agent_uid}:worker_env:{name}",
      action: "decrypt"
    )
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("worker_env_operation")
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

      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
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
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
    end

    action :console_delete, :map do
      transaction?(false)

      constraints(
        fields: [worker_env: [type: Ankole.AgentWorkers.WorkerEnv.ConsoleItem, allow_nil?: false]]
      )

      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
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
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
    end

    action :console_list_for_agent, :map do
      transaction?(false)

      constraints(
        fields: [
          worker_envs: [
            type: {:array, Ankole.AgentWorkers.WorkerEnv.ConsoleItem},
            allow_nil?: false
          ]
        ]
      )

      argument(:agent_uid, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
    end

    action :console_put_for_agent, :map do
      transaction?(false)

      constraints(
        fields: [worker_env: [type: Ankole.AgentWorkers.WorkerEnv.ConsoleItem, allow_nil?: false]]
      )

      argument(:agent_uid, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:value, :string, sensitive?: true, constraints: [trim?: false, allow_empty?: true])
      argument(:secret, :boolean)
      argument(:description, :string, constraints: [trim?: false, allow_empty?: true])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
    end

    action :console_delete_for_agent, :map do
      transaction?(false)

      constraints(
        fields: [worker_env: [type: Ankole.AgentWorkers.WorkerEnv.ConsoleItem, allow_nil?: false]]
      )

      argument(:agent_uid, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
    end

    action :console_decrypt_for_agent, :map do
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

      argument(:agent_uid, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:name, :string, allow_nil?: false, constraints: [trim?: false])
      run({Ankole.AgentWorkers.WorkerEnv.ConsoleActions, scope: :tenant})
    end
  end
end
