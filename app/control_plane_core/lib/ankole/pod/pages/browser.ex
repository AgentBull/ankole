defmodule Ankole.Pod.Pages.Browser do
  @moduledoc "The browser's page tree, document, and sharing operations."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [AshJsonApi.Resource]

  alias Ankole.Pod.{Documents, Pages, APIError}
  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey}

  @role [type: :atom, constraints: [one_of: [:view, :edit, :manage]], allow_nil?: false]
  @subject [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    name: [type: :string, allow_nil?: false],
    kind: [type: :atom, constraints: [one_of: [:human, :agent, :group]], allow_nil?: false]
  ]
  @grant [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    role: @role
  ]
  @page [type: :struct, constraints: [instance_of: Ankole.Pod.Page], allow_nil?: false]
  @content [type: :struct, constraints: [instance_of: Ankole.Pod.PageContent]]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("pod_page_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :list, :map do
      constraints(
        fields: [
          pages: [
            type: {:array, :struct},
            constraints: [items: [instance_of: Ankole.Pod.Page]],
            allow_nil?: false
          ],
          principal_uid: [type: PrincipalKey, allow_nil?: false]
        ]
      )

      argument(:scope, :atom,
        constraints: [one_of: [:all, :space, :private, :shared, :recent, :favorites, :trash]],
        default: :all,
        allow_nil?: false
      )

      argument(:query, :string)

      run(fn input, context ->
        opts = Map.update!(input.arguments, :scope, &to_string/1)

        Pages.list(context.actor.uid, opts)
        |> APIError.result(&%{pages: &1, principal_uid: context.actor.uid})
      end)
    end

    action :show, :map do
      constraints(
        fields: [
          page: @page,
          content: @content,
          role: @role,
          source_conversation: [
            type: :map,
            constraints: [
              fields: [
                id: [type: UUIDv7],
                title: [type: :string, constraints: [allow_empty?: true]],
                message_id: [type: UUIDv7],
                deleted: [type: :boolean]
              ]
            ]
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Pages.get(context.actor.uid, input.arguments.id))
      end)
    end

    action :create, :map do
      constraints(fields: [page: @page])

      argument(:type, :atom,
        constraints: [one_of: [:doc, :database, :applet, :file]],
        default: :doc
      )

      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:icon, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)
      argument(:position, :string, constraints: [trim?: false])
      argument(:saved_from_message_id, UUIDv7)

      run(fn input, context ->
        Pages.create(context.actor.uid, input.arguments) |> APIError.result(&%{page: &1})
      end)
    end

    action :update, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:icon, :string, constraints: [trim?: false, allow_empty?: true])

      run(fn input, context ->
        Pages.update(context.actor.uid, input.arguments.id, input.arguments)
        |> APIError.result(&%{page: &1})
      end)
    end

    action :move, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)
      argument(:after_id, UUIDv7)
      argument(:before_id, UUIDv7)

      run(fn input, context ->
        Pages.move(context.actor.uid, input.arguments.id, input.arguments)
        |> APIError.result(&%{page: &1})
      end)
    end

    action :delete, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.delete(context.actor.uid, input.arguments.id) |> APIError.result(&%{page: &1})
      end)
    end

    action :restore, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.restore(context.actor.uid, input.arguments.id) |> APIError.result(&%{page: &1})
      end)
    end

    action :delete_embed, :boolean do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:ref, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.delete_embed(context.actor.uid, input.arguments.id, input.arguments.ref)
        |> APIError.result(fn _ -> true end)
      end)
    end

    action :user_state, :map do
      constraints(
        fields: [
          user_state: [
            type: :struct,
            constraints: [instance_of: Ankole.Pod.PageUserState],
            allow_nil?: false
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:favorite, :boolean)
      argument(:visited, :boolean)

      run(fn input, context ->
        Pages.state(context.actor.uid, input.arguments.id, input.arguments)
        |> APIError.result(&%{user_state: &1})
      end)
    end

    action :sharing, :map do
      constraints(
        fields: [
          inherit_permissions: [type: :boolean, allow_nil?: false],
          sharing_version: [type: :string, allow_nil?: false],
          subjects: [
            type: {:array, :map},
            constraints: [items: [fields: @subject]],
            allow_nil?: false
          ],
          grants: [
            type: {:array, :map},
            constraints: [items: [fields: Keyword.merge(@subject, @grant)]],
            allow_nil?: false
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Pages.sharing(context.actor.uid, input.arguments.id))
      end)
    end

    action :subjects, :map do
      constraints(
        fields: [
          subjects: [
            type: {:array, :map},
            constraints: [items: [fields: @subject]],
            allow_nil?: false
          ]
        ]
      )

      run(fn _input, context ->
        Pages.subjects(context.actor.uid) |> APIError.result(&%{subjects: &1})
      end)
    end

    action :set_sharing, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:sharing_version, :string, allow_nil?: false)
      argument(:inherit_permissions, :boolean)
      argument(:grants, {:array, :map}, constraints: [items: [fields: @grant]])

      run(fn input, context ->
        Pages.set_sharing(context.actor.uid, input.arguments.id, input.arguments)
        |> APIError.result(&%{page: &1})
      end)
    end

    action :write, :map do
      constraints(fields: [page: @page, content: @content])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:base_revision, :integer, allow_nil?: false, constraints: [min: 0])
      argument(:xml, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      run(fn input, context ->
        APIError.result(
          Documents.write(
            context.actor.uid,
            input.arguments.id,
            input.arguments.base_revision,
            input.arguments.xml
          )
        )
      end)
    end

    action :reconcile_versions, :map do
      constraints(
        fields: [
          pages: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: UUIDv7, allow_nil?: false],
                  revision: [type: :integer, allow_nil?: false]
                ]
              ]
            ]
          ],
          tables: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: UUIDv7, allow_nil?: false],
                  data_version: [type: :integer, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      argument(:pages, {:array, UUIDv7}, default: [])
      argument(:tables, {:array, UUIDv7}, default: [])

      run(fn input, context ->
        APIError.result(
          Pages.reconcile_versions(
            context.actor.uid,
            input.arguments.pages,
            input.arguments.tables
          )
        )
      end)
    end

    action :space, :map do
      constraints(
        fields: [
          role: @role,
          can_manage: [type: :boolean, allow_nil?: false],
          agents: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: Keyword.merge(@subject, @grant)]]
          ]
        ]
      )

      run(fn _input, context -> APIError.result(Pages.space(context.actor.uid)) end)
    end

    action :set_space, :map do
      constraints(fields: [role: @role])
      argument(:role, :atom, constraints: [one_of: [:view, :edit, :manage]], allow_nil?: false)

      run(fn input, context ->
        APIError.result(Pages.set_space(context.actor.uid, input.arguments.role))
      end)
    end

    action :space_agent, :map do
      constraints(fields: [principal_uid: [type: PrincipalKey, allow_nil?: false], role: @role])
      argument(:principal_uid, PrincipalKey, allow_nil?: false)
      argument(:role, :atom, constraints: [one_of: [:view, :edit, :manage]], allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Pages.space_agent(
            context.actor.uid,
            input.arguments.principal_uid,
            input.arguments.role
          )
        )
      end)
    end

    action :remove_space_agent, :map do
      constraints(fields: [principal_uid: [type: PrincipalKey, allow_nil?: false]])
      argument(:uid, PrincipalKey, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Pages.remove_space_agent(context.actor.uid, input.arguments.uid))
      end)
    end
  end
end
