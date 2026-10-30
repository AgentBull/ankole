defmodule Ankole.Pod.Documents.History.Browser do
  @moduledoc "The browser's document checkpoint reads and explicit restore operation."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Ash.Types.{Timestamptz, UUIDv7}
  alias Ankole.Pod.{APIError, Documents.History}

  authz do
    scope(:pod)
    allow(:list, check: :guardrail)
    allow(:show, check: :guardrail)
    allow(:restore, check: :guardrail)
  end

  @snapshot [
    id: [type: UUIDv7, allow_nil?: false],
    revision: [type: :integer, allow_nil?: false],
    title: [type: :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true]],
    icon: [type: :string, constraints: [trim?: false, allow_empty?: true]],
    created_at: [type: :utc_datetime_usec, allow_nil?: false],
    document_updated_at: [type: :utc_datetime_usec, allow_nil?: false],
    reason: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:created, :baseline, :checkpoint, :before_restore, :restored]]
    ],
    author: [
      type: :map,
      allow_nil?: false,
      constraints: [
        fields: Ankole.Pod.BrowserFields.author_fields()
      ]
    ]
  ]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("pod_document_history_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :list, :map do
      constraints(
        fields: [
          snapshots: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @snapshot]]
          ],
          next_cursor: [type: :string],
          current_revision: [type: :integer, allow_nil?: false],
          current_updated_at: [type: :utc_datetime_usec, allow_nil?: false]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:cursor, :string)
      argument(:limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 100])

      run(fn input, context ->
        APIError.result(History.list(context.actor, input.arguments.id, input.arguments))
      end)
    end

    action :show, :map do
      constraints(
        fields: [
          snapshot: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields:
                @snapshot ++
                  [content: [type: :string, allow_nil?: false, constraints: [trim?: false]]]
            ]
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:snapshot_id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          History.read(context.actor, input.arguments.id, input.arguments.snapshot_id)
        )
      end)
    end

    action :restore, :map do
      constraints(
        fields: [
          page: [
            type: :struct,
            allow_nil?: false,
            constraints: struct_constraints(Ankole.Pod.Page)
          ],
          content: [
            type: :struct,
            allow_nil?: false,
            constraints: struct_constraints(Ankole.Pod.PageContent)
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:snapshot_id, UUIDv7, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])
      argument(:updated_at, Timestamptz, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          History.restore(
            context.actor,
            input.arguments.id,
            input.arguments.snapshot_id,
            input.arguments.base_revision,
            input.arguments.updated_at
          )
        )
      end)
    end
  end
end
