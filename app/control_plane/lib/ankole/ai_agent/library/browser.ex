defmodule Ankole.AIAgent.Library.Browser do
  @moduledoc "Typed Pod operations for Skill packages and Agent contracts."
  use Ankole.Ash.OperationResource,
    domain: Ankole.AIAgent,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension]

  alias Ankole.Ash.Types.{UUIDv7, JSONMap, PrincipalKey}

  authz do
    scope(:pod)

    for name <- [
          :list,
          :detail,
          :create,
          :save,
          :publish,
          :delete,
          :set_all,
          :set_binding,
          :put_file,
          :change_file,
          :read_file,
          :import,
          :contracts,
          :save_contract,
          :global_contracts,
          :save_global_contract
        ] do
      allow(name, check: :guardrail)
    end
  end

  json_api do
    type("meta_library")
  end

  @package_file [
    id: [type: UUIDv7, allow_nil?: false],
    relative_path: [type: :string, allow_nil?: false],
    mode: [type: :integer, allow_nil?: false],
    content_type: [type: :string, allow_nil?: false]
  ]
  @skill [
    id: [type: UUIDv7, allow_nil?: false],
    slug: [type: :string, allow_nil?: false],
    name: [type: :string, allow_nil?: false],
    description: [type: :string, allow_nil?: false],
    manifest_xml: [type: :string, allow_nil?: false],
    manifest_markdown: [type: :string, allow_nil?: false],
    metadata: [type: JSONMap, allow_nil?: false],
    revision: [type: :integer, allow_nil?: false],
    source_kind: [type: :string, allow_nil?: false],
    agent_plugin_id: [type: :string],
    agent_uid: [type: :string],
    colleague_count: [type: :integer, allow_nil?: false],
    assistant_enabled: [type: :boolean, allow_nil?: false],
    agent_uids: [type: {:array, :string}, allow_nil?: false],
    runtime_assistant_enabled: [type: :boolean, allow_nil?: false],
    runtime_agent_uids: [type: {:array, :string}, allow_nil?: false],
    enabled_for_all: [type: :boolean, allow_nil?: false],
    can_edit: [type: :boolean, allow_nil?: false],
    can_delete: [type: :boolean, allow_nil?: false],
    can_bind_all: [type: :boolean, allow_nil?: false],
    can_publish: [type: :boolean, allow_nil?: false]
  ]
  @contract [
    slot: [type: :string, allow_nil?: false],
    mode: [type: :string, allow_nil?: false],
    content_xml: [type: :string, allow_nil?: false],
    content_markdown: [type: :string, allow_nil?: false],
    metadata: [type: JSONMap, allow_nil?: false],
    revision: [type: :integer, allow_nil?: false]
  ]

  actions do
    action :list, :map do
      transaction?(false)

      constraints(
        fields: [
          skills: [
            type: {:array, :map},
            constraints: [items: [fields: @skill]],
            allow_nil?: false
          ],
          can_create: [type: :boolean, allow_nil?: false],
          can_create_workspace: [type: :boolean, allow_nil?: false]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :detail, :map do
      transaction?(false)
      argument(:slug, :string, allow_nil?: false)

      constraints(
        fields: [
          skill: [type: :map, constraints: [fields: @skill], allow_nil?: false],
          files: [
            type: {:array, :map},
            constraints: [items: [fields: @package_file]],
            allow_nil?: false
          ],
          agent_uids: [type: {:array, :string}, allow_nil?: false]
        ]
      )

      run(__MODULE__.Actions)
    end

    for name <- [:create, :save] do
      action name, :map do
        transaction?(false)

        if name == :create do
          argument(:slug, :string,
            default: "",
            allow_nil?: false,
            constraints: [allow_empty?: true]
          )

          argument(:personal, :boolean, default: false, allow_nil?: false)
          argument(:agent_uid, :string)
        else
          argument(:slug, :string, allow_nil?: false)
        end

        argument(:manifest_xml, :string,
          allow_nil?: false,
          constraints: [trim?: false, allow_empty?: true]
        )

        argument(:metadata, JSONMap, allow_nil?: false)

        if name == :save do
          argument(:new_slug, :string)
          argument(:base_revision, :integer, allow_nil?: false)
        end

        constraints(fields: @skill)
        run(__MODULE__.Actions)
      end
    end

    action :publish, :map do
      transaction?(false)
      argument(:slug, :string, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false)
      constraints(fields: @skill)
      run(__MODULE__.Actions)
    end

    action :delete, :boolean do
      transaction?(false)
      argument(:slug, :string, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    for name <- [:set_all, :set_binding] do
      action name, :map do
        transaction?(false)
        argument(:slug, :string, allow_nil?: false)
        argument(:enabled, :boolean, allow_nil?: false)
        if name == :set_all, do: argument(:base_revision, :integer, allow_nil?: false)
        if name == :set_binding, do: argument(:agent_uid, :string, allow_nil?: false)
        constraints(fields: @skill)
        run(__MODULE__.Actions)
      end
    end

    action :put_file, :map do
      transaction?(false)
      argument(:slug, :string, allow_nil?: false)
      argument(:path, :string, allow_nil?: false)

      argument(:content_base64, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true, trim?: false]
      )

      argument(:mode, :integer, default: 292, allow_nil?: false)
      argument(:content_type, :string, default: "application/octet-stream", allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false)
      constraints(fields: @skill)
      run(__MODULE__.Actions)
    end

    action :change_file, :map do
      transaction?(false)
      argument(:slug, :string, allow_nil?: false)
      argument(:path, :string, allow_nil?: false)
      argument(:new_path, :string)
      argument(:base_revision, :integer, allow_nil?: false)
      constraints(fields: @skill)
      run(__MODULE__.Actions)
    end

    action :read_file, :map do
      transaction?(false)
      argument(:slug, :string, allow_nil?: false)
      argument(:path, :string, allow_nil?: false)

      constraints(
        fields: [
          content_base64: [type: :string, allow_nil?: false],
          revision: [type: :integer, allow_nil?: false]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :import, :map do
      transaction?(false)

      argument(:slug, :string,
        default: "",
        allow_nil?: false,
        constraints: [allow_empty?: true]
      )

      argument(:content_base64, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:personal, :boolean, default: false, allow_nil?: false)
      argument(:agent_uid, :string)
      constraints(fields: @skill)
      run(__MODULE__.Actions)
    end

    for name <- [:contracts, :global_contracts] do
      action name, :map do
        transaction?(false)
        if name == :contracts, do: argument(:uid, PrincipalKey, allow_nil?: false)

        constraints(
          fields: [
            contracts: [
              type: {:array, :map},
              constraints: [
                items: [
                  fields: @contract ++ [effective_markdown: [type: :string, allow_nil?: false]]
                ]
              ],
              allow_nil?: false
            ],
            can_edit: [type: :boolean, allow_nil?: false]
          ]
        )

        run(__MODULE__.Actions)
      end
    end

    for name <- [:save_contract, :save_global_contract] do
      action name, :map do
        transaction?(false)
        if name == :save_contract, do: argument(:uid, PrincipalKey, allow_nil?: false)
        argument(:slot, :atom, constraints: [one_of: [:agents, :design]], allow_nil?: false)

        argument(:mode, :atom,
          constraints: [one_of: [:inherit, :append, :override]],
          allow_nil?: false
        )

        argument(:content_xml, :string,
          allow_nil?: false,
          constraints: [trim?: false, allow_empty?: true]
        )

        argument(:metadata, JSONMap, allow_nil?: false)
        argument(:base_revision, :integer, allow_nil?: false)
        constraints(fields: @contract)
        run(__MODULE__.Actions)
      end
    end
  end
end
