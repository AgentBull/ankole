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
    allow(:navigation, check: :guardrail)
    allow(:search, check: :guardrail)
    allow(:show, check: :guardrail)
    allow(:insights, check: :guardrail)
    allow(:viewers, check: :guardrail)
    allow(:create, check: :guardrail)
    allow(:update, check: :guardrail)
    allow(:move, check: :guardrail)
    allow(:delete, check: :guardrail)
    allow(:restore, check: :guardrail)
    allow(:purge, check: :guardrail)
    allow(:delete_embeds, check: :guardrail)
    allow(:user_state, check: :guardrail)
    allow(:sharing, check: :guardrail)
    allow(:subjects, check: :guardrail)
    allow(:set_sharing, check: :guardrail)
    allow(:update_sharing, check: :guardrail)
    allow(:write, check: :guardrail)
    allow(:reconcile_versions, check: :guardrail)
    allow(:space, check: :guardrail)
    allow(:set_space, check: :guardrail)
    allow(:space_agent, check: :guardrail)
    allow(:remove_space_agent, check: :guardrail)
    allow(:mention_candidates, check: :guardrail)
    allow(:resolve_mentions, check: :guardrail)
  end

  alias Ankole.Pod.{Documents, Pages, APIError}
  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey}

  @role [
    type: :atom,
    constraints: [one_of: [:view, :contribute, :edit, :manage]],
    allow_nil?: false
  ]
  @actions [
    type: {:array, :atom},
    allow_nil?: false,
    constraints: [
      items: [one_of: [:node_view, :node_contribute, :node_edit, :node_manage, :node_comment]]
    ]
  ]
  @subject [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    name: [type: :string, allow_nil?: false],
    kind: [
      type: :atom,
      constraints: [one_of: [:human, :agent, :group, :userset]],
      allow_nil?: false
    ],
    avatar_url: [type: :string],
    subtitle: [type: :string],
    membership: [type: :atom, constraints: [one_of: [:member, :guest]]],
    group_domain: [
      type: :atom,
      constraints: [one_of: [:operator, :directory, :im_group, :signal_source]]
    ],
    group_slug: [type: :string],
    built_in: [type: :boolean]
  ]
  @grant [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    source_node_id: [type: UUIDv7],
    source_action: [type: :string],
    target_scope: [type: :string, constraints: [match: ~r/\A(container|self)\z/]],
    condition: [type: :string, constraints: [trim?: false]],
    actions: Keyword.put(@actions, :allow_nil?, true),
    role: Keyword.put(@role, :allow_nil?, true)
  ]
  @sharing_upsert [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    role: @role,
    target_scope: [type: :string, constraints: [match: ~r/\A(container|self)\z/]]
  ]
  @sharing_remove [
    principal_uid: [type: PrincipalKey],
    group_id: [type: UUIDv7],
    source_node_id: [type: UUIDv7],
    source_action: [type: :string],
    target_scope: [
      type: :string,
      allow_nil?: false,
      constraints: [match: ~r/\A(container|self)\z/]
    ],
    condition: [type: :string, constraints: [trim?: false]]
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
  @inherited_collaborator Keyword.merge(@subject,
                            origin: [
                              type: :atom,
                              constraints: [
                                one_of: [
                                  :space_admin,
                                  :space_default,
                                  :space_agent,
                                  :private_owner,
                                  :ancestor
                                ]
                              ],
                              allow_nil?: false
                            ],
                            role: @role
                          )
  @sharing_fields [
    can_manage: [type: :boolean, allow_nil?: false],
    scope_kind: [type: :atom, constraints: [one_of: [:space, :private]], allow_nil?: false],
    space_name: [
      type: :string,
      allow_nil?: false,
      constraints: [allow_empty?: true, trim?: false]
    ],
    space_role: Keyword.put(@role, :allow_nil?, true),
    inherit_permissions: [type: :boolean, allow_nil?: false],
    sharing_version: [type: :string, allow_nil?: false],
    subjects: [
      type: {:array, :map},
      constraints: [items: [fields: @subject]],
      allow_nil?: false
    ],
    inherited: [
      type: {:array, :map},
      constraints: [items: [fields: @inherited_collaborator]],
      allow_nil?: false
    ],
    grants: [
      type: {:array, :map},
      constraints: [
        items: [
          fields:
            Keyword.merge(@subject, @grant)
            |> Keyword.put(:role, @role)
            |> Keyword.update!(:actions, &Keyword.put(&1, :allow_nil?, false))
            |> Keyword.put(:source_page, @source_page)
            |> Keyword.put(:rule_kind,
              type: :atom,
              constraints: [one_of: [:role, :advanced]],
              allow_nil?: false
            )
            |> Keyword.put(:inactive_in_private, type: :boolean, allow_nil?: false)
        ]
      ],
      allow_nil?: false
    ]
  ]
  @navigation_fields [
    name: [type: :string, allow_nil?: false],
    id: [type: UUIDv7, allow_nil?: false],
    has_children: [type: :boolean, allow_nil?: false],
    parent_id: [type: UUIDv7],
    private_owner_uid: [type: PrincipalKey],
    type: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:doc, :base, :applet, :file, :folder]]
    ],
    title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false]],
    icon: [type: :string],
    position: [type: :string],
    inherit_permissions: [type: :boolean, allow_nil?: false],
    role: @role,
    actions: @actions
  ]

  @directory_fields [
    pages: [
      type: {:array, :map},
      constraints: [items: [fields: @navigation_fields]],
      allow_nil?: false
    ],
    can_create_private: [type: :boolean, allow_nil?: false],
    can_create_space: [type: :boolean, allow_nil?: false],
    can_manage_space: [type: :boolean, allow_nil?: false],
    principal_uid: [type: PrincipalKey, allow_nil?: false],
    next_cursor: [type: :string]
  ]

  @file_preview_fields [
    path: [type: :string, allow_nil?: false, constraints: [trim?: false]],
    sha256: [type: :string, allow_nil?: false],
    size: [type: :integer, allow_nil?: false, constraints: [min: 0]],
    content_type: [type: :string, allow_nil?: false]
  ]

  @child_detail_fields [
    created_at: [type: :utc_datetime_usec],
    updated_at: [type: :utc_datetime_usec],
    created_by: [type: PrincipalKey],
    creator_name: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    excerpt: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    file: [type: :map, constraints: [fields: @file_preview_fields]]
  ]

  @children_directory_fields Keyword.put(@directory_fields, :pages,
                               type: {:array, :map},
                               constraints: [
                                 items: [fields: @navigation_fields ++ @child_detail_fields]
                               ],
                               allow_nil?: false
                             )

  @children_view_field [one_of: [:created_by, :updated_at, :created_at]]

  @children_view_fields [
    collapsed: [type: :boolean],
    view: [type: :atom, constraints: [one_of: [:list, :grid]]],
    field_order: [
      type: {:array, :atom},
      constraints: [items: @children_view_field]
    ],
    visible_fields: [
      type: {:array, :atom},
      constraints: [items: @children_view_field]
    ]
  ]

  @mention_page_candidate_fields [
    id: [type: UUIDv7, allow_nil?: false],
    type: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:doc, :base, :applet, :file, :folder]]
    ],
    title: [type: :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false]],
    icon: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    private_owner_uid: [type: PrincipalKey],
    ancestors: [
      type: {:array, :string},
      allow_nil?: false,
      constraints: [items: [allow_empty?: true, trim?: false]]
    ],
    updated_at: [type: :utc_datetime_usec, allow_nil?: false]
  ]

  @mention_principal_candidate_fields [
    principal_uid: [type: PrincipalKey, allow_nil?: false],
    kind: [type: :atom, allow_nil?: false, constraints: [one_of: [:human, :agent]]],
    name: [type: :string, allow_nil?: false, constraints: [allow_empty?: true, trim?: false]],
    avatar_url: [type: :string],
    membership: [type: :atom, constraints: [one_of: [:member, :guest]]],
    email: [type: :string],
    job_title: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    aliases: [type: {:array, :string}],
    role: [type: :string, constraints: [allow_empty?: true, trim?: false]]
  ]

  @mention_ranking_fields [
    kind: [type: :atom, allow_nil?: false, constraints: [one_of: [:page, :principal]]],
    id: [type: :string, allow_nil?: false]
  ]

  @mention_resolved_page_fields [
    id: [type: UUIDv7, allow_nil?: false],
    access: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:ok, :trashed, :restricted]]
    ],
    type: [type: :atom, constraints: [one_of: [:doc, :base, :applet, :file, :folder]]],
    title: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    icon: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    private_owner_uid: [type: PrincipalKey],
    ancestors: [
      type: {:array, :string},
      constraints: [items: [allow_empty?: true, trim?: false]]
    ],
    updated_at: [type: :utc_datetime_usec],
    excerpt: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    file: [type: :map, constraints: [fields: @file_preview_fields]]
  ]

  @mention_resolved_principal_fields [
    principal_uid: [type: PrincipalKey, allow_nil?: false],
    access: [
      type: :atom,
      allow_nil?: false,
      constraints: [one_of: [:ok, :disabled, :restricted]]
    ],
    kind: [type: :atom, constraints: [one_of: [:human, :agent]]],
    name: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    avatar_url: [type: :string],
    membership: [type: :atom, constraints: [one_of: [:member, :guest]]],
    email: [type: :string],
    job_title: [type: :string, constraints: [allow_empty?: true, trim?: false]],
    aliases: [type: {:array, :string}],
    role: [type: :string, constraints: [allow_empty?: true, trim?: false]]
  ]

  defp navigation_directory(result),
    do: Map.update!(result, :pages, &Enum.map(&1, fn page -> navigation_page(page) end))

  defp children_directory(result) do
    details = Map.get(result, :details)

    result
    |> Map.delete(:details)
    |> Map.update!(:pages, fn pages ->
      Enum.map(pages, fn page ->
        base = navigation_page(page)

        case details && Map.get(details, page.id) do
          nil -> base
          detail -> Map.merge(base, detail)
        end
      end)
    end)
  end

  defp navigation_page(page) do
    page
    |> Map.take(Keyword.keys(@navigation_fields))
    |> Map.put(:has_children, page.aggregates.has_children)
  end

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
    action :insights, :map do
      constraints(
        fields: [
          created_at: [type: :utc_datetime_usec, allow_nil?: false],
          updated_at: [type: :utc_datetime_usec, allow_nil?: false],
          hide_visits: [type: :boolean, allow_nil?: false],
          can_view_readers: [type: :boolean, allow_nil?: false],
          daily: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  day: [type: :date, allow_nil?: false],
                  views: [type: :integer, allow_nil?: false],
                  edits: [type: :integer, allow_nil?: false],
                  comments: [type: :integer, allow_nil?: false]
                ]
              ]
            ]
          ],
          contributors: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields:
                  Ankole.Pod.BrowserFields.author_fields() ++
                    [
                      role: [
                        type: :atom,
                        allow_nil?: false,
                        constraints: [one_of: [:creator, :last_edited, :previously_edited]]
                      ]
                    ]
              ]
            ]
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Ankole.Pod.Documents.Insights.read(context.actor, input.arguments.id))
      end)
    end

    action :viewers, :map do
      constraints(
        fields: [
          total: [type: :integer, allow_nil?: false],
          next_cursor: [type: :string],
          viewers: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  visited_at: [type: :utc_datetime_usec, allow_nil?: false],
                  person: [
                    type: :map,
                    allow_nil?: false,
                    constraints: [
                      fields: Ankole.Pod.BrowserFields.author_fields()
                    ]
                  ]
                ]
              ]
            ]
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:cursor, :string)
      argument(:limit, :integer, allow_nil?: false, default: 25, constraints: [min: 1, max: 100])

      run(fn input, context ->
        APIError.result(
          Ankole.Pod.Documents.Insights.viewers(
            context.actor,
            input.arguments.id,
            input.arguments
          )
        )
      end)
    end

    action :list, :map do
      constraints(
        fields: [
          pages: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Pod.Page)],
            allow_nil?: false
          ],
          trash_retention_days: [type: :integer]
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

        # Trash rows show the days left before the purge job removes them.
        retention =
          if opts.scope == "trash",
            do:
              Ankole.Repo.transact_repeatable_read_only(
                &Ankole.Files.Config.trash_retention_days/0
              ),
            else: {:ok, nil}

        with {:ok, pages} <- Pages.list(context.actor, opts),
             {:ok, days} <- retention do
          {:ok, %{pages: pages, trash_retention_days: days}}
        end
        |> APIError.result()
      end)
    end

    action :navigation, :map do
      constraints(
        fields: [
          directories: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields:
                  [parent_id: [type: UUIDv7], scope: [type: :string, allow_nil?: false]] ++
                    @directory_fields
              ]
            ]
          ],
          path: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @navigation_fields]]
          ]
        ]
      )

      argument(:active_page_id, UUIDv7)

      run(fn input, context ->
        Pages.navigation(context.actor, input.arguments[:active_page_id])
        |> APIError.result(fn result ->
          %{
            directories: Enum.map(result.directories, &navigation_directory/1),
            path: Enum.map(result.path, &navigation_page/1)
          }
        end)
      end)
    end

    action :children, :map do
      constraints(fields: @children_directory_fields)

      argument(:parent_id, UUIDv7)
      argument(:scope, :atom, constraints: [one_of: [:space, :private]], default: :space)
      argument(:cursor, :string)
      argument(:limit, :integer, constraints: [min: 1, max: 200], default: 200)
      argument(:details, :boolean, default: false)

      run(fn input, context ->
        APIError.result(
          Pages.list_children(
            context.actor,
            Map.get(input.arguments, :parent_id),
            input.arguments
          ),
          &children_directory/1
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
          ancestors: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Pod.Page)],
            allow_nil?: false
          ],
          principal_uid: [type: PrincipalKey, allow_nil?: false],
          can_create_private: [type: :boolean, allow_nil?: false],
          can_create_space: [type: :boolean, allow_nil?: false]
        ]
      )

      argument(:query, :string, allow_nil?: false, constraints: [allow_empty?: true])
      argument(:exclude_subtree_of, UUIDv7)
      argument(:embeddable, :boolean, allow_nil?: false, default: false)

      argument(:required_action, :atom,
        allow_nil?: false,
        default: :node_view,
        constraints: [one_of: [:node_view, :node_edit]]
      )

      run(fn input, context ->
        APIError.result(Pages.search(context.actor, input.arguments.query, input.arguments))
      end)
    end

    action :show, :map do
      constraints(
        fields: [
          page: @page,
          ancestors: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Pod.Page)],
            allow_nil?: false
          ],
          content: @content,
          role: @role,
          actions: @actions,
          child_count: [type: :integer, allow_nil?: false, constraints: [min: 0]],
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
        constraints: [one_of: [:doc, :base, :file, :folder]],
        default: :doc
      )

      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:icon, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)
      argument(:position, :string, constraints: [trim?: false])
      argument(:saved_from_message_id, UUIDv7)
      argument(:children_view, :map, constraints: [fields: @children_view_fields])
      argument(:xml, :string, constraints: [trim?: false])
      argument(:attachment_position, :integer, constraints: [min: 0])

      run(fn input, context ->
        result =
          if input.arguments[:attachment_position] do
            Ankole.Pod.Files.create_from_message(context.actor, input.arguments)
          else
            Pages.create(context.actor, input.arguments)
          end

        with {:ok, page} <- result do
          Ankole.Files.Access.authorize_with_permissions(context.actor, page)
        end
        |> APIError.result(&%{page: &1})
      end)
    end

    action :update, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:title, :string, constraints: [trim?: false, allow_empty?: true])

      argument(:expected_title, :string,
        constraints: [trim?: false, allow_empty?: true],
        description: "Required whenever title is supplied; the title read before editing."
      )

      argument(:icon, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:children_view, :map, constraints: [fields: @children_view_fields])

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
      constraints(fields: [page: @page, descendant_count: [type: :integer, allow_nil?: false]])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        # Count before the subtree is hidden; only Pages that the actor can view are counted.
        count = Pages.visible_descendant_count(context.actor, input.arguments.id)

        Pages.delete(context.actor, input.arguments.id)
        |> APIError.result(&%{page: &1, descendant_count: count})
      end)
    end

    action :restore, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.restore(context.actor, input.arguments.id) |> APIError.result(&%{page: &1})
      end)
    end

    action :purge, :map do
      constraints(fields: [page: @page])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Pages.purge(context.actor, input.arguments.id) |> APIError.result(&%{page: &1})
      end)
    end

    action :delete_embeds, :boolean do
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:refs, {:array, UUIDv7}, allow_nil?: false)

      run(fn input, context ->
        Pages.delete_embeds(context.actor, input.arguments.id, input.arguments.refs)
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
      argument(:hide_visits, :boolean)

      run(fn input, context ->
        Pages.state(context.actor, input.arguments.id, input.arguments)
        |> APIError.result(&%{user_state: &1})
      end)
    end

    action :sharing, :map do
      constraints(fields: @sharing_fields)

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

    action :update_sharing, :map do
      constraints(fields: @sharing_fields)
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:inherit_permissions, :boolean)
      argument(:upserts, {:array, :map}, constraints: [items: [fields: @sharing_upsert]])
      argument(:removes, {:array, :map}, constraints: [items: [fields: @sharing_remove]])

      run(fn input, context ->
        Pages.update_sharing(context.actor, input.arguments.id, input.arguments)
        |> APIError.result(& &1.sharing)
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
                  revision: [type: :integer, allow_nil?: false],
                  object_id: [type: UUIDv7]
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
              items: [
                fields:
                  Keyword.merge(@subject, @grant)
                  |> Keyword.put(:role, @role)
                  |> Keyword.put(:source_page, @source_page)
              ]
            ]
          ]
        ]
      )

      run(fn _input, context -> APIError.result(Pages.space(context.actor)) end)
    end

    action :set_space, :map do
      constraints(fields: [role: @role])

      argument(:role, :atom,
        constraints: [one_of: [:view, :contribute, :edit, :manage]],
        allow_nil?: false
      )

      run(fn input, context ->
        APIError.result(Pages.set_space(context.actor, input.arguments.role))
      end)
    end

    action :space_agent, :map do
      constraints(fields: [principal_uid: [type: PrincipalKey, allow_nil?: false], role: @role])
      argument(:principal_uid, PrincipalKey, allow_nil?: false)

      argument(:role, :atom,
        constraints: [one_of: [:view, :contribute, :edit, :manage]],
        allow_nil?: false
      )

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

    action :mention_candidates, :map do
      constraints(
        fields: [
          space_name: [
            type: :string,
            allow_nil?: false,
            constraints: [allow_empty?: true, trim?: false]
          ],
          total_all_matches: [type: :integer, allow_nil?: false, constraints: [min: 0]],
          pages: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @mention_page_candidate_fields]]
          ],
          principals: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @mention_principal_candidate_fields]]
          ],
          ranking: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @mention_ranking_fields]]
          ]
        ]
      )

      argument(:query, :string, default: "", constraints: [allow_empty?: true, trim?: false])

      argument(:category, :atom,
        default: :all,
        constraints: [one_of: [:all, :page, :principal]]
      )

      argument(:current_page_id, UUIDv7)
      argument(:limit, :integer, default: 20, constraints: [min: 1, max: 30])

      run(fn input, context ->
        APIError.result(Pages.mention_candidates(context.actor, input.arguments))
      end)
    end

    action :resolve_mentions, :map do
      constraints(
        fields: [
          space_name: [
            type: :string,
            allow_nil?: false,
            constraints: [allow_empty?: true, trim?: false]
          ],
          pages: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @mention_resolved_page_fields]]
          ],
          principals: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [items: [fields: @mention_resolved_principal_fields]]
          ]
        ]
      )

      argument(:page_ids, {:array, UUIDv7}, default: [])
      argument(:principal_uids, {:array, PrincipalKey}, default: [])
      argument(:context_page_id, UUIDv7)

      run(fn input, context ->
        APIError.result(Pages.resolve_mentions(context.actor, input.arguments))
      end)
    end
  end
end
