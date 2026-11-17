defmodule Ankole.Pod.Applets.Workspace do
  @moduledoc "Typed browser operations for Applet bindings, drafts and publication history."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  alias Ankole.Ash.Types.{JSONMap, UUIDv7}
  alias Ankole.Pod.APIError
  alias Ankole.Pod.Applets.{Bindings, Revisions}

  authz do
    scope(:pod)
    allow(:bindings, check: :guardrail)
    allow(:put_binding, check: :guardrail)
    allow(:delete_binding, check: :guardrail)
    allow(:revisions, check: :guardrail)
    allow(:draft, check: :guardrail)
    allow(:promote, check: :guardrail)
    allow(:discard, check: :guardrail)
    allow(:rollback, check: :guardrail)
  end

  json_api do
    type("applet_workspace_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  @revision [
    id: [type: UUIDv7, allow_nil?: false],
    revision: [type: :integer],
    base_revision: [type: :integer, allow_nil?: false],
    summary: [type: :string, constraints: [allow_empty?: true]],
    published_by: [type: :string],
    created_at: [type: Ankole.Ash.Types.Timestamptz, allow_nil?: false],
    updated_at: [type: Ankole.Ash.Types.Timestamptz, allow_nil?: false],
    restored_from_revision: [type: :integer]
  ]
  @bindings [
    bindings: [type: JSONMap, allow_nil?: false],
    bindings_digest: [type: :string, allow_nil?: false]
  ]

  actions do
    action :bindings, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields:
          @bindings ++
            [
              manifest: [type: JSONMap, allow_nil?: false],
              overrides: [type: JSONMap, allow_nil?: false]
            ]
      )

      run(fn input, ctx ->
        APIError.result(Bindings.list(ctx.actor, input.arguments.page_id))
      end)
    end

    action :put_binding, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:slot_key, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:table_id, UUIDv7)
      argument(:field_overrides, JSONMap, default: %{})
      constraints(fields: @bindings)

      run(fn input, ctx ->
        args = input.arguments
        APIError.result(Bindings.put(ctx.actor, args.page_id, args.slot_key, args))
      end)
    end

    action :delete_binding, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:slot_key, :string, allow_nil?: false, constraints: [trim?: false])
      constraints(fields: @bindings)

      run(fn input, ctx ->
        args = input.arguments
        APIError.result(Bindings.delete(ctx.actor, args.page_id, args.slot_key))
      end)
    end

    action :revisions, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)

      constraints(
        fields: [
          revisions: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @revision]]
          ],
          draft: [type: :map, constraints: [fields: @revision]]
        ]
      )

      run(fn input, ctx ->
        APIError.result(Revisions.list(ctx.actor, input.arguments.page_id))
      end)
    end

    action :draft, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:draft_id, UUIDv7, allow_nil?: false)

      constraints(
        fields:
          @bindings ++ [draft: [type: :map, allow_nil?: false, constraints: [fields: @revision]]]
      )

      run(fn input, ctx ->
        args = input.arguments
        APIError.result(Revisions.preview(ctx.actor, args.page_id, args.draft_id))
      end)
    end

    action :promote, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:expected_draft_id, UUIDv7, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])

      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false]
        ]
      )

      run(fn input, ctx ->
        args = input.arguments

        APIError.result(
          Revisions.promote(ctx.actor, args.page_id, args.expected_draft_id, args.base_revision)
        )
      end)
    end

    action :discard, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:expected_draft_id, UUIDv7, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])

      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false]
        ]
      )

      run(fn input, ctx ->
        args = input.arguments

        APIError.result(
          Revisions.discard(ctx.actor, args.page_id, args.expected_draft_id, args.base_revision)
        )
      end)
    end

    action :rollback, :map do
      transaction?(false)
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:target_revision, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])

      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false]
        ]
      )

      run(fn input, ctx ->
        args = input.arguments

        APIError.result(
          Revisions.rollback(ctx.actor, args.page_id, args.target_revision, args.base_revision)
        )
      end)
    end
  end
end
