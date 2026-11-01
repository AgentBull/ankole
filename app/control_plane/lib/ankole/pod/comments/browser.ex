defmodule Ankole.Pod.Comments.Browser do
  @moduledoc "Typed browser operations for document discussions and native text anchors."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Ash.Types.{UUIDv7, ActorRef, Timestamptz, JSONMap, PrincipalKey}
  alias Ankole.Pod.{Comments, APIError}
  alias Ankole.Pod.Comments.Activity

  authz do
    scope(:pod)
    allow(:list, check: :guardrail)
    allow(:show, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:update, check: :guardrail)
    allow(:delete, check: :guardrail)
    allow(:resolve, check: :guardrail)
    allow(:anchor, check: :guardrail)
    allow(:summary, check: :guardrail)
    allow(:acknowledge, check: :guardrail)
  end

  @comment [
    id: [type: UUIDv7, allow_nil?: false],
    root_id: [type: UUIDv7],
    body: [type: :string, constraints: [trim?: false, allow_empty?: true]],
    version: [type: :integer, allow_nil?: false],
    created_at: [type: :utc_datetime_usec, allow_nil?: false],
    updated_at: [type: :utc_datetime_usec, allow_nil?: false],
    activity_at: [type: :utc_datetime_usec, allow_nil?: false],
    deleted_at: [type: :utc_datetime_usec],
    resolved_at: [type: :utc_datetime_usec],
    resolved_by: [type: ActorRef],
    quote: [type: :string, constraints: [trim?: false, allow_empty?: true]],
    anchor: [type: JSONMap],
    anchor_revision: [type: :integer],
    anchor_present: [type: :boolean, allow_nil?: false],
    anchor_outdated: [type: :boolean, allow_nil?: false],
    can_edit: [type: :boolean, allow_nil?: false],
    can_delete: [type: :boolean, allow_nil?: false],
    can_resolve: [type: :boolean, allow_nil?: false],
    can_reanchor: [type: :boolean, allow_nil?: false],
    author: [
      type: :map,
      allow_nil?: false,
      constraints: [
        fields: Ankole.Pod.BrowserFields.author_fields()
      ]
    ]
  ]
  @result [
    comment: [type: :map, allow_nil?: false, constraints: [fields: @comment]],
    revision: [type: :integer, allow_nil?: false]
  ]
  @summary [
    unread_count: [type: :integer, allow_nil?: false],
    open_count: [type: :integer, allow_nil?: false],
    activity_at: [type: :utc_datetime_usec],
    resolved_ids: [type: {:array, UUIDv7}, allow_nil?: false]
  ]
  @thread @comment ++
            [
              unread: [type: :boolean, allow_nil?: false],
              replies: [
                type: {:array, :map},
                allow_nil?: false,
                constraints: [items: [fields: @comment]]
              ]
            ]

  json_api do
    type("pod_document_comment_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :summary, :map do
      constraints(fields: @summary)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Activity.summary(context.actor, input.arguments.id))
      end)
    end

    action :acknowledge, :map do
      constraints(fields: @summary)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:through, Timestamptz, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Activity.acknowledge(context.actor, input.arguments.id, input.arguments.through)
        )
      end)
    end

    action :list, :map do
      constraints(
        fields: [
          threads: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: @thread
              ]
            ]
          ],
          next_cursor: [type: :string],
          revision: [type: :integer, allow_nil?: false]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      argument(:status, :atom,
        allow_nil?: false,
        default: :open,
        constraints: [one_of: [:open, :resolved, :all, :unread]]
      )

      argument(:cursor, :string)
      argument(:limit, :integer, allow_nil?: false, default: 25, constraints: [min: 1, max: 100])

      run(fn input, context ->
        APIError.result(Comments.list(context.actor, input.arguments.id, input.arguments))
      end)
    end

    action :show, :map do
      constraints(
        fields: [
          thread: [type: :map, allow_nil?: false, constraints: [fields: @thread]],
          revision: [type: :integer, allow_nil?: false]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:comment_id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Comments.read(context.actor, input.arguments.id, input.arguments.comment_id)
        )
      end)
    end

    action :create, :map do
      constraints(fields: @result)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:root_id, UUIDv7)
      argument(:body, :string, allow_nil?: false, constraints: [trim?: false, max_length: 20_000])
      argument(:base_revision, :integer, constraints: [min: 0])
      argument(:from, :integer, constraints: [min: 0])
      argument(:to, :integer, constraints: [min: 1])
      argument(:quote, :string, constraints: [trim?: false, max_length: 1_000])
      argument(:anchor, JSONMap)
      argument(:mentioned_agent_uids, {:array, PrincipalKey})

      run(fn input, context ->
        APIError.result(Comments.create(context.actor, input.arguments.id, input.arguments))
      end)
    end

    action :update, :map do
      constraints(fields: @result)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:comment_id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:body, :string, allow_nil?: false, constraints: [trim?: false, max_length: 20_000])
      argument(:mentioned_agent_uids, {:array, PrincipalKey})

      run(fn input, context ->
        APIError.result(
          Comments.update(
            context.actor,
            input.arguments.id,
            input.arguments.comment_id,
            input.arguments
          )
        )
      end)
    end

    action :delete, :map do
      constraints(fields: @result)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:comment_id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])

      run(fn input, context ->
        APIError.result(
          Comments.delete(
            context.actor,
            input.arguments.id,
            input.arguments.comment_id,
            input.arguments
          )
        )
      end)
    end

    action :resolve, :map do
      constraints(fields: @result)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:comment_id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:resolved, :boolean, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Comments.resolve(
            context.actor,
            input.arguments.id,
            input.arguments.comment_id,
            input.arguments
          )
        )
      end)
    end

    action :anchor, :map do
      constraints(fields: @result)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:comment_id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:base_revision, :integer, constraints: [min: 0])
      argument(:from, :integer, constraints: [min: 0])
      argument(:to, :integer, constraints: [min: 1])
      argument(:quote, :string, constraints: [trim?: false, max_length: 1_000])
      argument(:anchor, JSONMap)

      run(fn input, context ->
        APIError.result(
          Comments.anchor(
            context.actor,
            input.arguments.id,
            input.arguments.comment_id,
            input.arguments
          )
        )
      end)
    end
  end
end
