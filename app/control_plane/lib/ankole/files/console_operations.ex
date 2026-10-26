defmodule Ankole.Files.ConsoleOperations do
  @moduledoc "Typed Console operations that call the Ankole.Files owner."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Files,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    resolve_param(:agent_uid, :principal_key)
    allow(:console_list, resource: "site_console:agent:{agent_uid}:files", action: "read")
    allow(:console_move, resource: "site_console:agent:{agent_uid}:files", action: "update")
    allow(:console_delete, resource: "site_console:agent:{agent_uid}:files", action: "delete")
    allow(:console_download, resource: "site_console:agent:{agent_uid}:files", action: "read")
    allow(:console_upload, resource: "site_console:agent:{agent_uid}:files", action: "update")
  end

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("files_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :console_download, :struct do
      transaction?(false)
      constraints(instance_of: Ankole.Files.Schemas.DriveFile)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:path, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:local_path, :string, allow_nil?: false)
      run(Ankole.Files.ConsoleActions)
    end

    action :console_upload, :struct do
      transaction?(false)
      constraints(instance_of: Ankole.Files.Schemas.DriveFile)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:path, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:local_path, :string, allow_nil?: false)
      argument(:content_type, :string)
      run(Ankole.Files.ConsoleActions)
    end

    action :console_list, :map do
      transaction?(false)

      constraints(
        fields: [
          file_listing: [
            type: :map,
            constraints: [
              fields: [
                files: [
                  type: {:array, :map},
                  constraints: [
                    items: [
                      fields: [
                        content_type: [
                          type: :string,
                          constraints: [trim?: false, allow_empty?: true],
                          allow_nil?: false
                        ],
                        conversation_id: [
                          type: :string,
                          constraints: [trim?: false, allow_empty?: true]
                        ],
                        message_id: [
                          type: :string,
                          constraints: [trim?: false, allow_empty?: true]
                        ],
                        path: [
                          type: :string,
                          constraints: [trim?: false, allow_empty?: true],
                          allow_nil?: false
                        ],
                        size: [type: :integer, allow_nil?: false],
                        source: [
                          type: :atom,
                          constraints: [
                            one_of: [:inbound, :generated, :sent, :agent, :console, :pod]
                          ],
                          allow_nil?: false
                        ],
                        updated_at: [
                          type: :string,
                          constraints: [trim?: false, allow_empty?: true],
                          allow_nil?: false
                        ]
                      ]
                    ]
                  ],
                  allow_nil?: false
                ],
                folders: [
                  type: {:array, :map},
                  constraints: [
                    items: [
                      fields: [
                        name: [
                          type: :string,
                          constraints: [trim?: false, allow_empty?: true],
                          allow_nil?: false
                        ],
                        path: [
                          type: :string,
                          constraints: [trim?: false, allow_empty?: true],
                          allow_nil?: false
                        ]
                      ]
                    ]
                  ],
                  allow_nil?: false
                ],
                path: [
                  type: :string,
                  constraints: [trim?: false, allow_empty?: true],
                  allow_nil?: false
                ],
                truncated: [type: :boolean, allow_nil?: false]
              ]
            ],
            allow_nil?: false
          ]
        ]
      )

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:path, :string, constraints: [trim?: false, allow_empty?: true], default: "")
      run(Ankole.Files.ConsoleActions)
    end

    action :console_move, :map do
      transaction?(false)
      constraints(fields: [moved_files: [type: :integer, allow_nil?: false]])

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:from_path, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:to_path, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      run(Ankole.Files.ConsoleActions)
    end

    action :console_delete, :map do
      transaction?(false)
      constraints(fields: [deleted_files: [type: :integer, allow_nil?: false]])

      argument(:agent_uid, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:path, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      run(Ankole.Files.ConsoleActions)
    end
  end
end
