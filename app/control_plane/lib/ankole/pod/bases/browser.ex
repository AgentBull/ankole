defmodule Ankole.Pod.Bases.Browser do
  @moduledoc "Typed browser operations for Bases schemas and versioned record batches."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:pod)
    allow(:tables, check: :guardrail)
    allow(:create_table, check: :guardrail)
    allow(:delete_table, check: :guardrail)
    allow(:show, check: :guardrail)
    allow(:query, check: :guardrail)
    allow(:aggregate, check: :guardrail)
    allow(:write, check: :guardrail)
    allow(:create_field, check: :guardrail)
    allow(:update_field, check: :guardrail)
    allow(:delete_field, check: :guardrail)
    allow(:create_view, check: :guardrail)
    allow(:update_view, check: :guardrail)
    allow(:delete_view, check: :guardrail)
    allow(:copy, check: :guardrail)
  end

  alias Ankole.Pod.{Bases, APIError, Serialization}
  alias Ankole.Pod.Bases.{Record, RecordData, FieldVersions, Value}
  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey, JSONMap}

  @table [
    type: :struct,
    constraints: struct_constraints(Ankole.Pod.BaseTable),
    allow_nil?: false
  ]
  @field [
    type: :struct,
    constraints: struct_constraints(Ankole.Pod.BaseField),
    allow_nil?: false
  ]
  @view [
    type: :struct,
    constraints: struct_constraints(Ankole.Pod.BaseView),
    allow_nil?: false
  ]
  @field_types Ash.Resource.Info.attribute(Ankole.Pod.BaseField, :type).constraints
  @view_types Ash.Resource.Info.attribute(Ankole.Pod.BaseView, :type).constraints
  @filter [
    fields: [
      conjunction: [type: :atom, constraints: [one_of: [:and, :or]], allow_nil?: false],
      conditions: [
        type: {:array, :map},
        allow_nil?: false,
        constraints: [
          items: [
            fields: [
              field_id: [type: UUIDv7, allow_nil?: false],
              operator: [
                type: :atom,
                allow_nil?: false,
                constraints: [
                  one_of: [
                    :is,
                    :contains,
                    :is_empty,
                    :is_not_empty,
                    :gt,
                    :gte,
                    :lt,
                    :lte,
                    :text_contains
                  ]
                ]
              ],
              value: [type: Value]
            ]
          ]
        ]
      ]
    ]
  ]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("pod_base_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :tables, :map do
      constraints(
        fields: [
          tables: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Pod.BaseTable)],
            allow_nil?: false
          ]
        ]
      )

      argument(:page_id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Bases.list_tables(context.actor, input.arguments.page_id))
      end)
    end

    action :create_table, :map do
      constraints(fields: [table: @table])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:name, :string)

      run(fn input, context ->
        Bases.create_table(context.actor, input.arguments.page_id, attrs(input))
        |> APIError.result(&%{table: &1})
      end)
    end

    action :delete_table, :map do
      constraints(fields: [table: @table])
      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        Bases.delete_table(context.actor, input.arguments.id)
        |> APIError.result(&%{table: &1})
      end)
    end

    action :show, :map do
      constraints(
        fields: [
          table: @table,
          fields: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Pod.BaseField)],
            allow_nil?: false
          ],
          views: [
            type: {:array, :struct},
            constraints: [items: struct_constraints(Ankole.Pod.BaseView)],
            allow_nil?: false
          ],
          mode: [type: :atom, constraints: [one_of: [:local, :remote]], allow_nil?: false],
          timezone: [type: :string, allow_nil?: false],
          local_query: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                text_contains_ascii: [type: :boolean, allow_nil?: false],
                jsonb_compare: [type: :boolean, allow_nil?: false]
              ]
            ]
          ],
          limits: [
            type: :map,
            allow_nil?: false,
            constraints: [
              fields: [
                query_rows: [type: :integer, allow_nil?: false],
                record_bytes: [type: :integer, allow_nil?: false],
                group_count: [type: :integer, allow_nil?: false],
                statement_timeout_ms: [type: :integer, allow_nil?: false]
              ]
            ]
          ]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Bases.get_table(context.actor, input.arguments.id))
      end)
    end

    action :query, :map do
      constraints(
        fields: [
          records: [type: {:array, Record}, allow_nil?: false],
          data_version: [type: :integer, allow_nil?: false],
          page_token: [type: :string],
          complete: [type: :boolean, allow_nil?: false]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:filter, :map, constraints: @filter)

      argument(:sort, {:array, :map},
        constraints: [
          items: [
            fields: [
              field_id: [type: UUIDv7, allow_nil?: false],
              direction: [type: :atom, constraints: [one_of: [:asc, :desc]], allow_nil?: false]
            ]
          ]
        ]
      )

      argument(:group, :map,
        constraints: [
          fields: [
            field_id: [type: UUIDv7, allow_nil?: false],
            value: [type: Value],
            value_json: [type: :string]
          ]
        ]
      )

      argument(:page_size, :integer, constraints: [min: 1])
      argument(:page_token, :string)
      argument(:ids, {:array, UUIDv7})
      argument(:local, :boolean)

      run(fn input, context ->
        APIError.result(Bases.query(context.actor, input.arguments.id, attrs(input)))
      end)
    end

    action :aggregate, :map do
      constraints(
        fields: [
          groups: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  values: [
                    type: {:array, Value},
                    allow_nil?: false,
                    constraints: [nil_items?: true]
                  ],
                  value_json: [
                    type: {:array, :string},
                    allow_nil?: false,
                    constraints: [nil_items?: true]
                  ],
                  metrics: [type: RecordData, allow_nil?: false]
                ]
              ]
            ]
          ],
          data_version: [type: :integer, allow_nil?: false]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:filter, :map, constraints: @filter)

      argument(:group_by, {:array, :map},
        constraints: [
          items: [
            fields: [
              field_id: [type: UUIDv7, allow_nil?: false],
              bucket: [type: :atom, constraints: [one_of: [:day, :week, :month, :quarter, :year]]]
            ]
          ]
        ]
      )

      argument(:metrics, {:array, :map},
        allow_nil?: false,
        constraints: [
          items: [
            fields: [
              operation: [
                type: :atom,
                allow_nil?: false,
                constraints: [one_of: [:count, :sum, :avg, :min, :max]]
              ],
              field_id: [type: UUIDv7],
              alias: [type: :string, allow_nil?: false]
            ]
          ]
        ]
      )

      run(fn input, context ->
        APIError.result(Bases.aggregate(context.actor, input.arguments.id, attrs(input)))
      end)
    end

    action :write, :map do
      constraints(
        fields: [
          records: [type: {:array, Record}, allow_nil?: false],
          deleted_ids: [type: {:array, UUIDv7}, allow_nil?: false],
          data_version: [type: :integer, allow_nil?: false]
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)

      argument(:creates, {:array, :map},
        constraints: [
          items: [fields: [id: [type: UUIDv7], data: [type: RecordData, allow_nil?: false]]]
        ]
      )

      argument(:updates, {:array, :map},
        constraints: [
          items: [
            fields: [
              id: [type: UUIDv7, allow_nil?: false],
              data: [type: RecordData, allow_nil?: false],
              expected_versions: [type: FieldVersions, allow_nil?: false]
            ]
          ]
        ]
      )

      argument(:deletes, {:array, :map},
        constraints: [
          items: [
            fields: [
              id: [type: UUIDv7, allow_nil?: false],
              expected_versions: [type: FieldVersions, allow_nil?: false]
            ]
          ]
        ]
      )

      run(fn input, context ->
        Bases.write_records(context.actor, input.arguments.id, attrs(input))
        |> APIError.result(&Serialization.json_value/1)
      end)
    end

    action :create_field, :map do
      constraints(fields: [field: @field])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:name, :string)
      argument(:position, :string)
      argument(:type, :atom, constraints: @field_types)
      argument(:config, JSONMap)
      argument(:is_primary, :boolean)

      run(fn input, context ->
        Bases.create_field(context.actor, input.arguments.id, attrs(input))
        |> APIError.result(&%{field: &1})
      end)
    end

    action :update_field, :map do
      constraints(fields: [field: @field])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:name, :string)
      argument(:position, :string)
      argument(:type, :atom, constraints: @field_types)
      argument(:config, JSONMap)
      argument(:clear_invalid, :boolean)

      run(fn input, context ->
        Bases.update_field(context.actor, input.arguments.id, attrs(input))
        |> APIError.result(&%{field: &1})
      end)
    end

    action :delete_field, :map do
      constraints(fields: [field: @field])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])

      run(fn input, context ->
        Bases.delete_field(context.actor, input.arguments.id, input.arguments.version)
        |> APIError.result(&%{field: &1})
      end)
    end

    action :create_view, :map do
      constraints(fields: [view: @view])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:name, :string)
      argument(:position, :string)
      argument(:type, :atom, constraints: @view_types)
      argument(:config, JSONMap)

      run(fn input, context ->
        Bases.create_view(context.actor, input.arguments.id, attrs(input))
        |> APIError.result(&%{view: &1})
      end)
    end

    action :update_view, :map do
      constraints(fields: [view: @view])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])
      argument(:name, :string)
      argument(:position, :string)
      argument(:type, :atom, constraints: @view_types)
      argument(:config, JSONMap)

      run(fn input, context ->
        Bases.update_view(context.actor, input.arguments.id, attrs(input))
        |> APIError.result(&%{view: &1})
      end)
    end

    action :delete_view, :map do
      constraints(fields: [view: @view])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])

      run(fn input, context ->
        Bases.delete_view(context.actor, input.arguments.id, input.arguments.version)
        |> APIError.result(&%{view: &1})
      end)
    end

    action :copy, :map do
      constraints(
        fields: [
          page: [
            type: :struct,
            constraints: struct_constraints(Ankole.Pod.Page),
            allow_nil?: false
          ],
          table: @table
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)
      argument(:title, :string)
      argument(:filter, :map, constraints: @filter)

      run(fn input, context ->
        APIError.result(Bases.copy_table(context.actor, input.arguments.id, attrs(input)))
      end)
    end
  end

  # Bases query operators are JSON strings. Ash validates their finite vocabulary first.
  defp attrs(input), do: Serialization.json_value(input.arguments)
end
