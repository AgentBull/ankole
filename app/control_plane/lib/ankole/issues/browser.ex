defmodule Ankole.Issues.Browser do
  @moduledoc "The current Human's work items and schedules in the selected Pod."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Issues,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Ash.Types.{PrincipalKey, UUIDv7}
  alias Ankole.Issues
  alias Ankole.Issues.View
  alias Ankole.Pod.APIError

  authz do
    scope(:pod)
    allow(:scheduled, check: :guardrail)
    allow(:list, check: :guardrail)
    allow(:show, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:update, check: :guardrail)
    allow(:change_schedule, check: :guardrail)
  end

  json_api do
    type("issue_operation")
  end

  actions do
    action :list, :map do
      constraints(fields: [issues: [type: {:array, View}, allow_nil?: false]])

      run(fn _input, context ->
        APIError.result(Issues.list(context.actor), &%{issues: &1})
      end)
    end

    action :show, View do
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Issues.get(context.actor, input.arguments.id))
      end)
    end

    # The Agent starts at once unless `start` is false. `repeat` runs the request
    # on a cron schedule; `parentID` makes a sub-Issue; `squadUIDs` names the
    # colleagues among whom a personal assistant shares the work.
    action :create, View do
      argument(:title, :string, allow_nil?: false)
      argument(:description, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:agentUID, PrincipalKey, allow_nil?: false)
      argument(:start, :boolean, default: true)
      argument(:labels, {:array, :string})
      argument(:parentID, UUIDv7)
      argument(:squadUIDs, {:array, PrincipalKey})

      argument(:repeat, :map,
        constraints: [
          fields: [
            expression: [type: :string, allow_nil?: false],
            timezone: [type: :string, allow_nil?: false]
          ]
        ]
      )

      run(fn input, context ->
        arguments = input.arguments

        Issues.create(context.actor, %{
          title: arguments.title,
          description: arguments[:description],
          agent_uid: arguments.agentUID,
          start: arguments.start,
          labels: arguments[:labels],
          parent_id: arguments[:parentID],
          squad_uids: arguments[:squadUIDs],
          repeat: arguments[:repeat]
        })
        |> APIError.result()
      end)
    end

    # `status: started` starts a `todo` Issue or reopens a `done` one, and
    # `status: done` accepts the result. `description` changes the request of an
    # Issue in `todo`, and `labels` replaces its labels.
    action :update, View do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:description, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:status, :atom, constraints: [one_of: [:started, :done]])
      argument(:labels, {:array, :string})

      run(fn input, context ->
        arguments = input.arguments

        Issues.update(context.actor, arguments.id, %{
          description: arguments[:description],
          status: arguments[:status],
          labels: arguments[:labels]
        })
        |> APIError.result()
      end)
    end

    # Pauses, resumes, runs, or removes a cron rule that runs on the Human's authority.
    action :change_schedule, :map do
      argument(:id, UUIDv7, allow_nil?: false)

      argument(:change, :atom,
        allow_nil?: false,
        constraints: [one_of: [:pause, :resume, :run, :remove]]
      )

      constraints(fields: [id: [type: UUIDv7, allow_nil?: false]])

      run(fn input, context ->
        Issues.change_schedule(context.actor, input.arguments.id, input.arguments.change)
        |> APIError.result(&%{id: &1})
      end)
    end

    action :scheduled, :map do
      constraints(
        fields: [
          schedules: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  kind: [type: :string, allow_nil?: false],
                  id: [type: :string, allow_nil?: false],
                  title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true]],
                  status: [type: :string, allow_nil?: false],
                  agentUID: [type: PrincipalKey, allow_nil?: false],
                  agentName: [type: :string, allow_nil?: false],
                  manageable: [type: :boolean, allow_nil?: false],
                  conversationID: [type: UUIDv7, allow_nil?: false],
                  conversationTitle: [
                    type: :string,
                    allow_nil?: false,
                    constraints: [allow_empty?: true]
                  ],
                  schedule: [type: Ankole.Ash.Types.JSONMap],
                  timezone: [type: :string],
                  dueAt: [type: :utc_datetime_usec],
                  lastFiredAt: [type: :utc_datetime_usec]
                ]
              ]
            ]
          ]
        ]
      )

      run(fn _input, context ->
        APIError.result(Issues.scheduled(context.actor), &%{schedules: &1})
      end)
    end
  end
end
