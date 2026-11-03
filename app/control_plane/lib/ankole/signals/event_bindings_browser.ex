defmodule Ankole.Signals.EventBindingsBrowser do
  @moduledoc "Authorized management of event Bindings."
  use Ankole.Ash.OperationResource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Signals,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Signals.EventBindings
  alias Ankole.Ash.Types.{UUIDv7, JSONMap, PrincipalKey}

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
      argument(:config_ref, :string, allow_nil?: false)

      constraints(
        fields: [
          bindings: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Signals.Binding)],
            allow_nil?: false
          ]
        ]
      )

      run(fn input, context ->
        Ankole.Pod.APIError.result(
          EventBindings.list(context.actor, input.arguments.config_ref),
          &%{bindings: &1}
        )
      end)
    end

    action :put, :map do
      constraints(
        fields: [
          binding: [
            type: :struct,
            constraints: struct_constraints(Ankole.Signals.Binding),
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
          &%{binding: &1}
        )
      end)
    end
  end
end
