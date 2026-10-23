defmodule Ankole.Files.ConsoleOperations do
  @moduledoc "Typed Console operations that call the Ankole.Files owner."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Files,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("files_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
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
