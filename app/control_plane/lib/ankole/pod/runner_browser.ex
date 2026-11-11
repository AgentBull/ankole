defmodule Ankole.Pod.RunnerBrowser do
  @moduledoc "The current Pod member's device enrollment and Agent bindings."

  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.AgentWorkers
  alias Ankole.Ash.Types.{PrincipalKey, UUIDv7}
  alias Ankole.Pod.APIError

  @binding [
    agentUID: [type: PrincipalKey, allow_nil?: false],
    displayName: [type: :string, allow_nil?: true],
    agentType: [type: :string, allow_nil?: true],
    status: [type: :string, allow_nil?: false]
  ]

  @colleague [
    uid: [type: PrincipalKey, allow_nil?: false],
    displayName: [type: :string, allow_nil?: false],
    agentType: [type: :string, allow_nil?: false]
  ]

  @device [
    id: [type: UUIDv7, allow_nil?: false],
    name: [type: :string, allow_nil?: false],
    status: [type: :string, allow_nil?: false],
    bindings: [
      type: {:array, :map},
      allow_nil?: false,
      constraints: [items: [fields: @binding]]
    ]
  ]

  authz do
    scope(:pod)
    allow(:list, check: :guardrail)
    allow(:register, check: :guardrail)
    allow(:bind, check: :guardrail)
    allow(:revoke, check: :guardrail)
    allow(:create_job, check: :guardrail)
  end

  json_api do
    type("pod_runner_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :list, :map do
      transaction?(false)

      constraints(
        fields: [
          devices: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @device]]
          ],
          colleagues: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @colleague]]
          ]
        ]
      )

      run(fn _input, context ->
        AgentWorkers.list_runner_devices_with_colleagues(context.actor)
        |> APIError.result(&Function.identity/1)
      end)
    end

    action :register, :map do
      transaction?(false)
      argument(:name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 80])

      constraints(
        fields: [
          id: [type: UUIDv7, allow_nil?: false],
          code: [type: :string, allow_nil?: false],
          url: [type: :string, allow_nil?: false]
        ]
      )

      run(fn input, context ->
        AgentWorkers.register_runner_device(
          context.actor,
          input.arguments.name,
          AnkoleWeb.PodURL.site_origin(input.context.conn)
        )
        |> APIError.result(&Function.identity/1)
      end)
    end

    action :bind, :map do
      transaction?(false)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:agentUID, PrincipalKey, allow_nil?: false)
      constraints(fields: @device)

      run(fn input, context ->
        AgentWorkers.bind_runner_device(
          context.actor,
          input.arguments.id,
          input.arguments.agentUID,
          AnkoleWeb.PodURL.site_origin(input.context.conn)
        )
        |> APIError.result(&Function.identity/1)
      end)
    end

    action :create_job, :map do
      transaction?(false)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:agentUID, PrincipalKey, allow_nil?: false)
      argument(:runnerID, UUIDv7, allow_nil?: false)
      argument(:requestID, UUIDv7, allow_nil?: false)
      argument(:title, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 200])

      argument(:task, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 20_000]
      )

      constraints(fields: [jobID: [type: :integer, allow_nil?: false]])

      run(fn input, context ->
        Ankole.Pod.RunnerJobs.create(context.actor, input.arguments) |> APIError.result()
      end)
    end

    action :revoke, :map do
      transaction?(false)
      argument(:id, UUIDv7, allow_nil?: false)
      constraints(fields: [revoked: [type: :boolean, allow_nil?: false]])

      run(fn input, context ->
        AgentWorkers.revoke_runner_device(context.actor, input.arguments.id)
        |> APIError.result(fn _ -> %{revoked: true} end)
      end)
    end
  end
end
