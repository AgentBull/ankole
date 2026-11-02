defmodule Ankole.Pod.Spreadsheets.Browser do
  @moduledoc "Spreadsheet page creation, editor bootstrap, and version history for browsers."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:create, check: :guardrail)
    allow(:bootstrap, check: :guardrail)
    allow(:versions, check: :guardrail)
    allow(:restore, check: :guardrail)
  end

  alias Ankole.Pod.{APIError, Serialization, Spreadsheets}
  alias Ankole.Ash.Types.{JSONMap, PrincipalKey, UUIDv7}

  @file_fields [
    path: [type: :string, allow_nil?: false],
    object_id: [type: UUIDv7, allow_nil?: false],
    sha256: [type: :string, allow_nil?: false],
    size: [type: :integer, allow_nil?: false],
    content_type: [type: :string]
  ]
  @op_fields [
    revision: [type: :integer, allow_nil?: false],
    client_id: [type: :string, allow_nil?: false, constraints: [trim?: false]],
    client_seq: [type: :integer, allow_nil?: false],
    op: [type: JSONMap, allow_nil?: false]
  ]
  @version_fields [
    id: [type: UUIDv7, allow_nil?: false],
    revision: [type: :integer, allow_nil?: false],
    sha256: [type: :string, allow_nil?: false],
    size: [type: :integer, allow_nil?: false],
    file_name: [type: :string, allow_nil?: false, constraints: [trim?: false]],
    reason: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:created, :uploaded, :checkpoint, :before_restore, :restored]]
    ],
    author: [
      type: :map,
      allow_nil?: false,
      constraints: [fields: Ankole.Pod.BrowserFields.author_fields()]
    ],
    created_at: [type: Ankole.Ash.Types.Timestamptz, allow_nil?: false]
  ]

  json_api do
    type("pod_spreadsheet_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :create, :map do
      constraints(
        fields: [
          page: [
            type: :struct,
            constraints: struct_constraints(Ankole.Pod.Page),
            allow_nil?: false
          ]
        ]
      )

      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)

      run(fn input, context ->
        APIError.result(
          Spreadsheets.create_blank(context.actor, input.arguments),
          &%{page: &1}
        )
      end)
    end

    action :bootstrap, :map do
      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false],
          file: [type: :map, allow_nil?: false, constraints: [fields: @file_fields]],
          ops: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @op_fields]]
          ],
          metadata: [type: JSONMap]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Spreadsheets.bootstrap(context.actor, input.arguments.id))
      end)
    end

    action :versions, :map do
      constraints(
        fields: [
          versions: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @version_fields]]
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Spreadsheets.versions(context.actor, input.arguments.id), fn versions ->
          profiles = Serialization.author_profiles(Enum.map(versions, & &1.author))
          %{versions: Enum.map(versions, &Serialization.spreadsheet_version_json(&1, profiles))}
        end)
      end)
    end

    action :restore, :map do
      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false],
          file: [type: :map, allow_nil?: false, constraints: [fields: @file_fields]]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version_id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Spreadsheets.restore(context.actor, input.arguments.id, input.arguments.version_id)
        )
      end)
    end
  end
end
