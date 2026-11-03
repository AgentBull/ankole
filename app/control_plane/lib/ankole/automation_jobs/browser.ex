defmodule Ankole.AutomationJobs.Browser do
  @moduledoc "Page-authorized Applet Jobs and Run progress."
  use Ankole.Ash.OperationResource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.AutomationJobs,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.AutomationJobs.Applet
  alias Ankole.Pod.APIError
  alias Ankole.Ash.Types.{UUIDv7, JSONMap}

  @job [
    type: :struct,
    constraints: struct_constraints(Ankole.AutomationJobs.Schemas.Job),
    allow_nil?: false
  ]
  @run [
    type: :struct,
    constraints: struct_constraints(Ankole.AutomationJobs.Schemas.Run),
    allow_nil?: false
  ]
  resource do
    require_primary_key?(false)
  end

  authz do
    scope(:pod)
    allow(:list, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:configure, check: :guardrail)
    allow(:delete, check: :guardrail)
    allow(:run, check: :guardrail)
  end

  json_api do
    type("applet_job_operation")
  end

  actions do
    action :list, :map do
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields: [
          jobs: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.AutomationJobs.Schemas.Job)],
            allow_nil?: false
          ]
        ]
      )

      run(fn input, context ->
        APIError.result(Applet.list(context.actor, input.arguments.page_id), &%{jobs: &1})
      end)
    end

    action :create, :map do
      constraints(fields: [job: @job])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:action_key, :string, allow_nil?: false)

      argument(:authorization_kind, :string,
        default: "human",
        constraints: [match: ~r/\A(human|service)\z/]
      )

      argument(:config, JSONMap, default: %{})
      argument(:label, :string)

      run(fn input, context ->
        APIError.result(
          Applet.create(
            context.actor,
            input.arguments.page_id,
            input.arguments.action_key,
            Map.reject(input.arguments, fn {_, v} -> is_nil(v) end)
          ),
          &%{job: &1}
        )
      end)
    end

    action :configure, :map do
      constraints(fields: [job: @job])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:id, :integer, allow_nil?: false)
      argument(:config, JSONMap)
      argument(:label, :string)

      run(fn input, context ->
        APIError.result(
          Applet.configure(
            context.actor,
            input.arguments.page_id,
            input.arguments.id,
            Map.reject(input.arguments, fn {_, v} -> is_nil(v) end)
          ),
          &%{job: &1}
        )
      end)
    end

    action :delete, :map do
      constraints(fields: [job: @job])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:id, :integer, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Applet.delete(context.actor, input.arguments.page_id, input.arguments.id),
          &%{job: &1}
        )
      end)
    end

    action :run, :map do
      constraints(fields: [run: @run])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:id, :integer, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Applet.run(context.actor, input.arguments.page_id, input.arguments.id),
          &%{run: &1}
        )
      end)
    end
  end
end
