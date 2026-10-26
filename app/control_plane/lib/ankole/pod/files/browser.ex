defmodule Ankole.Pod.Files.Browser do
  @moduledoc "Page file manifests and atomic publication through the browser API."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:manifest, check: :guardrail)
    allow(:publish, check: :guardrail)
    allow(:copy, check: :guardrail)
  end

  alias Ankole.Pod.{Files, APIError}
  alias Ankole.Ash.Types.UUIDv7

  @entry_fields [
    path: [type: :string, allow_nil?: false],
    sha256: [type: :string, allow_nil?: false],
    size: [type: :integer, allow_nil?: false],
    content_type: [type: :string]
  ]
  @manifest [
    page_id: [type: UUIDv7, allow_nil?: false],
    revision: [type: :integer, allow_nil?: false],
    files: [
      type: {:array, :map},
      allow_nil?: false,
      constraints: [items: [fields: @entry_fields]]
    ],
    routes: [type: {:array, :string}]
  ]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("pod_file_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :manifest, :map do
      constraints(fields: @manifest)
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Files.manifest(context.actor, input.arguments.id))
      end)
    end

    action :publish, :map do
      constraints(fields: @manifest)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])

      argument(:files, {:array, :map},
        allow_nil?: false,
        constraints: [items: [fields: Keyword.delete(@entry_fields, :size)]]
      )

      run(fn input, context ->
        APIError.result(
          Files.publish(
            context.actor,
            input.arguments.id,
            input.arguments.base_revision,
            input.arguments.files
          )
        )
      end)
    end

    action :copy, :map do
      constraints(
        fields: [
          page_id: [type: UUIDv7, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false],
          file: [type: :map, allow_nil?: false, constraints: [fields: @entry_fields]],
          src: [type: :string]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])
      argument(:message_id, UUIDv7, allow_nil?: false)
      argument(:path, :string, allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Files.copy_from_message(
            context.actor,
            input.arguments.id,
            input.arguments.base_revision,
            input.arguments.message_id,
            input.arguments.path
          )
        )
      end)
    end
  end
end
