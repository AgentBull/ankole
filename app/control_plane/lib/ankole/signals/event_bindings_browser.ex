defmodule Ankole.Signals.EventBindingsBrowser do
  @moduledoc "Authorized management of event Bindings."
  use Ankole.Ash.OperationResource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Signals,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Signals.EventBindings
  alias Ankole.Ash.Types.{UUIDv7, JSONMap, PrincipalKey, State}

  @binding [
    id: [type: UUIDv7, allow_nil?: false],
    routing_mode: [
      type: State,
      constraints: [one_of: [:ai_colleague, :sender_personal_assistant, :action]],
      allow_nil?: false
    ],
    agent_uid: [type: PrincipalKey],
    automation_job_id: [type: :integer],
    watched_field_ids: [type: {:array, :string}],
    name: [type: :string, constraints: [trim?: true], allow_nil?: false],
    adapter: [type: :string, allow_nil?: false],
    config_ref: [type: :string, allow_nil?: false],
    target: [type: JSONMap, allow_nil?: false],
    filters: [type: JSONMap, allow_nil?: false],
    unaddressed_group_message_policy: [
      type: State,
      constraints: [one_of: [:ignore, :record_only, :may_intervene]],
      allow_nil?: false
    ],
    unmatched_sender_policy: [
      type: State,
      constraints: [one_of: [:manual_review, :create_standalone]],
      allow_nil?: false
    ],
    enabled: [type: :boolean, allow_nil?: false],
    unavailable_reason: [type: :string]
  ]

  resource do
    require_primary_key?(false)
  end

  authz do
    scope(:pod)
    allow(:list, check: :guardrail)
    allow(:put, check: :guardrail)
  end

  json_api do
    type("event_binding_operation")
  end

  actions do
    action :list, :map do
      argument(:config_ref, :string)
      argument(:job_id, :integer)

      constraints(
        fields: [
          bindings: [
            type: {:array, :map},
            constraints: [items: [fields: @binding]],
            allow_nil?: false
          ]
        ]
      )

      run(fn input, context ->
        Ankole.Pod.APIError.result(
          EventBindings.list(
            context.actor,
            Map.get(input.arguments, :config_ref),
            Map.get(input.arguments, :job_id)
          ),
          fn bindings -> %{bindings: Enum.map(bindings, &binding_json/1)} end
        )
      end)
    end

    action :put, :map do
      constraints(
        fields: [
          binding: [
            type: :map,
            constraints: [fields: @binding],
            allow_nil?: false
          ]
        ]
      )

      argument(:id, UUIDv7)
      argument(:config_ref, :string, allow_nil?: false)
      argument(:name, :string)
      argument(:automation_job_id, :integer)
      argument(:agent_uid, PrincipalKey)
      argument(:target, JSONMap)
      argument(:filters, JSONMap)
      argument(:watched_field_ids, {:array, UUIDv7})
      argument(:enabled, :boolean, default: true)

      run(fn input, context ->
        Ankole.Pod.APIError.result(
          EventBindings.put(
            context.actor,
            Map.reject(input.arguments, fn {_, v} -> is_nil(v) end)
          ),
          &%{binding: binding_json(&1)}
        )
      end)
    end
  end

  defp binding_json(binding), do: Map.take(binding, Keyword.keys(@binding))
end
