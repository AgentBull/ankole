defmodule Ankole.Pod.Pages.Browser do
  @moduledoc "The browser's page tree, document, and sharing operations."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:list, check: :guardrail)
    allow(:children, check: :guardrail)
    allow(:search, check: :guardrail)
    allow(:show, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:update, check: :guardrail)
    allow(:move, check: :guardrail)
    allow(:delete, check: :guardrail)
    allow(:restore, check: :guardrail)
    allow(:delete_embed, check: :guardrail)
    allow(:user_state, check: :guardrail)
    allow(:sharing, check: :guardrail)
    allow(:subjects, check: :guardrail)
    allow(:set_sharing, check: :guardrail)
    allow(:write, check: :guardrail)
    allow(:reconcile_versions, check: :guardrail)
    allow(:space, check: :guardrail)
    allow(:set_space, check: :guardrail)
    allow(:space_agent, check: :guardrail)
    allow(:remove_space_agent, check: :guardrail)
  end

  alias Ankole.Pod.{Documents, Pages, APIError}
  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey}

  @role [type: :atom, constraints: [one_of: [:view, :edit, :manage]], allow_nil?: false]
  @subject [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    name: [type: :string, allow_nil?: false],
    kind: [
      type: :atom,
      constraints: [one_of: [:human, :agent, :group, :userset]],
      allow_nil?: false
    ]
  ]
  @grant [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    source_page_id: [type: UUIDv7],
    source_action: [type: :string],
    target_scope: [type: :string, constraints: [match: ~r/\A(container|self)\z/]],
    condition: [type: :string, constraints: [trim?: false]],
    role: @role
  ]
  @source_page [
    type: :map,
    constraints: [
      fields: [
        id: [type: UUIDv7],
        accessible: [type: :boolean],
        title: [type: :string, constraints: [allow_empty?: true]],
        icon: [type: :string, constraints: [allow_empty?: true]]
      ]
    ]
  ]
  @navigation_fields [
    id: [type: UUIDv7, allow_nil?: false],
    parent_id: [type: UUIDv7],
    private_owner_uid: [type: PrincipalKey],
    type: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:doc, :database, :applet, :file]]
    ],
    title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false]],
    icon: [type: :string],
    position: [type: :string, allow_nil?: false],
    inherit_permissions: [type: :boolean, allow_nil?: false],
    role: @role
  ]

  @page [type: :struct, constraints: struct_constraints(Ankole.Pod.Page), allow_nil?: false]
  @content [type: :struct, constraints: struct_constraints(Ankole.Pod.PageContent)]

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
            constraints: [items: struct_constraints(Ankole.Pod.Page)],
            allow_nil?: false
          ],
          principal_uid: [type: PrincipalKey, allow_nil?: false],
          can_create_private: [type: :boolean, allow_nil?: false]
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

        Pages.list(context.actor, opts)
        |> APIError.result(
          &%{
            pages: &1,
            principal_uid: Ankole.AuthZ.Actor.uid(context.actor),
            can_create_private: Pages.can_create_private?(context.actor)
          }
        )
      end)
    end

    action :children, :map do
      constraints(
        fields: [
          pages: [
            type: {:array, :map},
            constraints: [items: [fields: @navigation_fields]],
            allow_nil?: false
          ],
          can_create_private: [type: :boolean, allow_nil?: false],
          principal_uid: [type: PrincipalKey, allow_nil?: false],
          next_cursor: [type: :string]
        ]
      )

      argument(:parent_id, UUIDv7)
      argument(:scope, :atom, constraints: [one_of: [:space, :private]], default: :space)
      argument(:cursor, :string)
      argument(:limit, :integer, constraints: [min: 1, max: 200], default: 200)

      run(fn input, context ->
        APIError.result(
          Pages.list_children(
            context.actor,
            Map.get(input.arguments, :parent_id),
            input.arguments
          ),
          fn result ->
            Map.update!(result, :pages, fn pages ->
              Enum.map(pages, &Map.take(&1, Keyword.keys(@navigation_fields)))
            end)
          end
        )
      end)
    end

    action :search, :map do
      constraints(
        fields: [
          pages: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Pod.Page)],
            allow_nil?: false
          ],
          principal_uid: [type: PrincipalKey, allow_nil?: false],
          can_create_private: [type: :boolean, allow_nil?: false]
        ]
      )

      argument(:query, :string, allow_nil?: false, constraints: [allow_empty?: true])
      argument(:exclude_subtree_of, UUIDv7)

      run(fn input, context ->
        APIError.result(Pages.search(context.actor, input.arguments.query, input.arguments))
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
        APIError.result(Pages.get(context.actor, input.arguments.id))
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
        Pages.create(context.actor, input.arguments) |> APIError.result(&%{page: &1})
      end)
    end

    action :update, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:icon, :string, constraints: [trim?: false, allow_empty?: true])

      run(fn input, context ->
        Pages.update(context.actor, input.arguments.id, input.arguments)
        |> APIError.result(&%{page: &1})
      end)
    end

    action :move, :map do
      constraints(
        fields: [
          page: @page,
          undo: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                parent_id: [type: UUIDv7],
                private_owner_uid: [type: PrincipalKey],
                before_id: [type: UUIDv7],
                after_id: [type: UUIDv7]
              ]
            ]
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)
      argument(:after_id, UUIDv7)
      argument(:before_id, UUIDv7)

      run(fn input, context ->
        Pages.move(context.actor, input.arguments.id, input.arguments)
        |> APIError.result()
      end)
    end

    action :delete, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.delete(context.actor, input.arguments.id) |> APIError.result(&%{page: &1})
      end)
    end

    action :restore, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.restore(context.actor, input.arguments.id) |> APIError.result(&%{page: &1})
      end)
    end

    action :delete_embed, :boolean do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:ref, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.delete_embed(context.actor, input.arguments.id, input.arguments.ref)
        |> APIError.result(fn _ -> true end)
      end)
    end

    action :user_state, :map do
      constraints(
        fields: [
          user_state: [
            type: :struct,
            constraints: struct_constraints(Ankole.Pod.PageUserState),
            allow_nil?: false
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:favorite, :boolean)
      argument(:visited, :boolean)

      run(fn input, context ->
        Pages.state(context.actor, input.arguments.id, input.arguments)
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
            constraints: [
              items: [fields: Keyword.merge(@subject, @grant) ++ [source_page: @source_page]]
            ],
            allow_nil?: false
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Pages.sharing(context.actor, input.arguments.id))
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
        Pages.subjects(context.actor) |> APIError.result(&%{subjects: &1})
      end)
    end

    action :set_sharing, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:sharing_version, :string, allow_nil?: false)
      argument(:inherit_permissions, :boolean)
      argument(:grants, {:array, :map}, constraints: [items: [fields: @grant]])

      run(fn input, context ->
        Pages.set_sharing(context.actor, input.arguments.id, input.arguments)
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
            context.actor,
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
            context.actor,
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
            constraints: [
              items: [fields: Keyword.merge(@subject, @grant) ++ [source_page: @source_page]]
            ]
          ]
        ]
      )

      run(fn _input, context -> APIError.result(Pages.space(context.actor)) end)
    end

    action :set_space, :map do
      constraints(fields: [role: @role])
      argument(:role, :atom, constraints: [one_of: [:view, :edit, :manage]], allow_nil?: false)

      run(fn input, context ->
        APIError.result(Pages.set_space(context.actor, input.arguments.role))
      end)
    end

    action :space_agent, :map do
      constraints(fields: [principal_uid: [type: PrincipalKey, allow_nil?: false], role: @role])
      argument(:principal_uid, PrincipalKey, allow_nil?: false)
      argument(:role, :atom, constraints: [one_of: [:view, :edit, :manage]], allow_nil?: false)

      run(fn input, context ->
        APIError.result(
          Pages.space_agent(
            context.actor,
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
        APIError.result(Pages.remove_space_agent(context.actor, input.arguments.uid))
      end)
    end
  end
end
