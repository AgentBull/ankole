defmodule Ankole.Pod.Database.Browser do
  @moduledoc "Typed browser operations for Database schemas and versioned record batches."
  use Ash.Resource,
    data_layer: Ash.DataLayer.Simple,
    domain: Ankole.Pod,
    extensions: [AshJsonApi.Resource]

  alias Ankole.Pod.{Database, APIError, Serialization}
  alias Ankole.Pod.Database.{Record, RecordData, FieldVersions, Value}
  alias Ankole.Ash.Types.{UUIDv7, PrincipalKey, JSONMap}

  @table [type: :struct, constraints: [instance_of: Ankole.Pod.DbTable], allow_nil?: false]
  @field [type: :struct, constraints: [instance_of: Ankole.Pod.DbField], allow_nil?: false]
  @view [type: :struct, constraints: [instance_of: Ankole.Pod.DbView], allow_nil?: false]
  @field_types Ash.Resource.Info.attribute(Ankole.Pod.DbField, :type).constraints
  @view_types Ash.Resource.Info.attribute(Ankole.Pod.DbView, :type).constraints
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
    type("pod_database_operation")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :tables, :map do
      constraints(
        fields: [
          tables: [
            type: {:array, :struct},
            constraints: [items: [instance_of: Ankole.Pod.DbTable]],
            allow_nil?: false
          ]
        ]
      )

      argument(:page_id, UUIDv7, allow_nil?: false)

      run(fn input, context ->
        APIError.result(Database.list_tables(context.actor.uid, input.arguments.page_id))
      end)
    end

    action :create_table, :map do
      constraints(fields: [table: @table])
      argument(:page_id, UUIDv7, allow_nil?: false)
      argument(:name, :string)

      run(fn input, context ->
        Database.create_table(context.actor.uid, input.arguments.page_id, attrs(input))
        |> APIError.result(&%{table: &1})
      end)
    end

    action :show, :map do
      constraints(
        fields: [
          table: @table,
          fields: [
            type: {:array, :struct},
            constraints: [items: [instance_of: Ankole.Pod.DbField]],
            allow_nil?: false
          ],
          views: [
            type: {:array, :struct},
            constraints: [items: [instance_of: Ankole.Pod.DbView]],
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
                local_rows: [type: :integer, allow_nil?: false],
                local_bytes: [type: :integer, allow_nil?: false],
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
        APIError.result(Database.get_table(context.actor.uid, input.arguments.id))
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
        APIError.result(Database.query(context.actor.uid, input.arguments.id, attrs(input)))
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
        APIError.result(Database.aggregate(context.actor.uid, input.arguments.id, attrs(input)))
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
        Database.write_records(context.actor.uid, input.arguments.id, attrs(input))
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
        Database.create_field(context.actor.uid, input.arguments.id, attrs(input))
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
        Database.update_field(context.actor.uid, input.arguments.id, attrs(input))
        |> APIError.result(&%{field: &1})
      end)
    end

    action :delete_field, :map do
      constraints(fields: [field: @field])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])

      run(fn input, context ->
        Database.delete_field(context.actor.uid, input.arguments.id, input.arguments.version)
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
        Database.create_view(context.actor.uid, input.arguments.id, attrs(input))
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
        Database.update_view(context.actor.uid, input.arguments.id, attrs(input))
        |> APIError.result(&%{view: &1})
      end)
    end

    action :delete_view, :map do
      constraints(fields: [view: @view])
      argument(:id, UUIDv7, allow_nil?: false)
      argument(:version, :integer, allow_nil?: false, constraints: [min: 1])

      run(fn input, context ->
        Database.delete_view(context.actor.uid, input.arguments.id, input.arguments.version)
        |> APIError.result(&%{view: &1})
      end)
    end

    action :copy, :map do
      constraints(
        fields: [
          page: [type: :struct, constraints: [instance_of: Ankole.Pod.Page], allow_nil?: false],
          table: @table
        ]
      )

      argument(:id, UUIDv7, allow_nil?: false)
      argument(:parent_id, UUIDv7)
      argument(:private_owner_uid, PrincipalKey)
      argument(:title, :string)
      argument(:filter, :map, constraints: @filter)

      run(fn input, context ->
        APIError.result(Database.copy_table(context.actor.uid, input.arguments.id, attrs(input)))
      end)
    end
  end

  # Database query operators are JSON strings. Ash validates their finite vocabulary first.
  defp attrs(input), do: Serialization.json_value(input.arguments)
end
