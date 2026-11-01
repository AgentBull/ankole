defmodule Ankole.Files.ConsoleOperations do
  @moduledoc "Site Console operations on every tenant's Drive roots and nodes."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Files,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_list, resource: "site_console:drive", action: "read")
    allow(:console_create, resource: "site_console:drive", action: "update")
    allow(:console_move, resource: "site_console:drive", action: "update")
    allow(:console_delete, resource: "site_console:drive", action: "delete")
    allow(:console_download, resource: "site_console:drive", action: "read")
    allow(:console_upload, resource: "site_console:drive", action: "update")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("drive_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_list, :map do
      transaction?(false)

      constraints(
        fields: [
          nodes: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  id: [type: :uuid, allow_nil?: false],
                  parent_id: [type: :uuid],
                  name: [type: :string, allow_nil?: false],
                  kind: [type: :string, allow_nil?: false],
                  object_id: [type: :uuid],
                  private_owner_uid: [type: :string],
                  conversation_id: [type: :uuid],
                  size: [type: :integer, allow_nil?: false],
                  content_type: [type: :string],
                  updated_at: [type: :string, allow_nil?: false]
                ]
              ]
            ],
            allow_nil?: false
          ],
          ancestors: [
            type: {:array, :map},
            constraints: [
              items: [
                fields: [
                  id: [type: :uuid, allow_nil?: false],
                  name: [type: :string, allow_nil?: false]
                ]
              ]
            ],
            allow_nil?: false
          ],
          next_after: [type: :string]
        ]
      )

      argument(:tenant_id, :uuid, allow_nil?: false)
      argument(:parent_id, :uuid)
      argument(:owner_uid, Ankole.Ash.Types.PrincipalKey)
      argument(:relative_path, :string)
      argument(:after, :string)
      argument(:limit, :integer, default: 200, constraints: [min: 1, max: 1000])
      run(Ankole.Files.ConsoleActions)
    end

    action :console_create, :map do
      transaction?(false)
      constraints(fields: [id: [type: :uuid, allow_nil?: false]])
      argument(:tenant_id, :uuid, allow_nil?: false)
      argument(:parent_id, :uuid, allow_nil?: false)
      argument(:name, :string, allow_nil?: false)
      argument(:kind, :atom, default: :folder, constraints: [one_of: [:folder, :file]])
      run(Ankole.Files.ConsoleActions)
    end

    action :console_move, :map do
      transaction?(false)
      constraints(fields: [id: [type: :uuid, allow_nil?: false]])
      argument(:tenant_id, :uuid, allow_nil?: false)
      argument(:id, :uuid, allow_nil?: false)
      argument(:parent_id, :uuid)
      argument(:name, :string)
      run(Ankole.Files.ConsoleActions)
    end

    action :console_delete, :map do
      transaction?(false)
      constraints(fields: [id: [type: :uuid, allow_nil?: false]])
      argument(:tenant_id, :uuid, allow_nil?: false)
      argument(:id, :uuid, allow_nil?: false)
      run(Ankole.Files.ConsoleActions)
    end

    action :console_download, :map do
      transaction?(false)

      constraints(
        fields: [
          node: [
            type: :struct,
            allow_nil?: false,
            constraints: [instance_of: Ankole.Files.Schemas.Node]
          ],
          object: [type: :struct, constraints: [instance_of: Ankole.Files.Schemas.FileObject]]
        ]
      )

      argument(:tenant_id, :uuid, allow_nil?: false)
      argument(:id, :uuid, allow_nil?: false)
      run(Ankole.Files.ConsoleActions)
    end

    action :console_upload, :map do
      transaction?(false)
      argument(:tenant_id, :uuid, allow_nil?: false)
      argument(:parent_id, :uuid, allow_nil?: false)
      argument(:name, :string, allow_nil?: false)
      argument(:local_path, :string, allow_nil?: false)
      argument(:content_type, :string)
      run(Ankole.Files.ConsoleActions)
    end
  end
end
