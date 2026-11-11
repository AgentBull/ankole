defmodule Ankole.Pod.OfficeFiles.Browser do
  @moduledoc "Office page creation, editor bootstrap, version history, and Word-to-Document conversion for browsers."
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
    allow(:convert_to_document, check: :guardrail)
  end

  alias Ankole.Pod.{APIError, OfficeFiles, Serialization}
  alias Ankole.Ash.Types.{JSONMap, PrincipalKey, UUIDv7}

  @format_values [:spreadsheet, :word, :presentation]

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
    type("pod_office_operation")
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

      argument(:format, :atom, allow_nil?: false, constraints: [one_of: @format_values])
      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)

      run(fn input, context ->
        APIError.result(
          OfficeFiles.create_blank(context.actor, input.arguments),
          &Serialization.with_private_owners(%{page: &1})
        )
      end)
    end

    action :bootstrap, :map do
      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false],
          format: [type: :atom, allow_nil?: false, constraints: [one_of: @format_values]],
          file: [type: :map, allow_nil?: false, constraints: [fields: @file_fields]],
          ops: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @op_fields]]
          ],
          checkpoint: [type: :string, constraints: [trim?: false]],
          metadata: [type: JSONMap]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(OfficeFiles.bootstrap(context.actor, input.arguments.id))
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
        APIError.result(OfficeFiles.versions(context.actor, input.arguments.id), fn versions ->
          profiles = Serialization.author_profiles(Enum.map(versions, & &1.author))
          %{versions: Enum.map(versions, &Serialization.office_version_json(&1, profiles))}
        end)
      end)
    end

    action :restore, :map do
      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false],
          format: [type: :atom, allow_nil?: false, constraints: [one_of: @format_values]],
          file: [type: :map, allow_nil?: false, constraints: [fields: @file_fields]]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version_id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          OfficeFiles.restore(context.actor, input.arguments.id, input.arguments.version_id)
        )
      end)
    end

    action :convert_to_document, :map do
      constraints(
        fields: [
          page: [
            type: :struct,
            constraints: struct_constraints(Ankole.Pod.Page),
            allow_nil?: false
          ],
          omitted: [type: JSONMap, allow_nil?: false],
          downgraded: [type: JSONMap, allow_nil?: false]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)

      run(fn input, context ->
        APIError.result(
          OfficeFiles.convert_to_document(
            context.actor,
            input.arguments.id,
            Map.delete(input.arguments, :id)
          ),
          &Serialization.with_private_owners/1
        )
      end)
    end
  end
end
