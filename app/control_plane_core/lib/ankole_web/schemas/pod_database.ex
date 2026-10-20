defmodule AnkoleWeb.Schemas.PodDatabase do
  @moduledoc "Browser contracts for Pod database schemas, records, and queries."
  alias OpenApiSpex.Schema

  defmodule Table do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodTable",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          page_id: %Schema{type: :string},
          name: %Schema{type: :string},
          position: %Schema{type: :string},
          data_version: %Schema{type: :integer},
          record_count: %Schema{type: :integer},
          next_auto_number: %Schema{type: :integer}
        },
        required: [
          :id,
          :page_id,
          :name,
          :position,
          :data_version,
          :record_count,
          :next_auto_number
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Tables do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodTables",
        type: :object,
        properties: %{tables: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Table}},
        required: [:tables],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule TableResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodTableResult",
        type: :object,
        properties: %{table: AnkoleWeb.Schemas.PodDatabase.Table},
        required: [:table],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule TableCreate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodTableCreate",
        type: :object,
        properties: %{name: %Schema{type: :string}},
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Field do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodField",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          table_id: %Schema{type: :string},
          name: %Schema{type: :string},
          position: %Schema{type: :string},
          type: %Schema{
            type: :string,
            enum: [
              "text",
              "number",
              "select",
              "datetime",
              "checkbox",
              "user",
              "attachment",
              "auto_number",
              "link",
              "formula",
              "created_at",
              "updated_at",
              "created_by",
              "updated_by"
            ]
          },
          config: %Schema{type: :object, additionalProperties: true},
          is_primary: %Schema{type: :boolean},
          version: %Schema{type: :integer}
        },
        required: [:id, :table_id, :name, :position, :type, :config, :is_primary, :version],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FieldResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFieldResult",
        type: :object,
        properties: %{field: AnkoleWeb.Schemas.PodDatabase.Field},
        required: [:field],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FieldWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFieldWrite",
        type: :object,
        properties: %{
          name: %Schema{type: :string},
          position: %Schema{type: :string},
          type: %Schema{
            type: :string,
            enum: [
              "text",
              "number",
              "select",
              "datetime",
              "checkbox",
              "user",
              "attachment",
              "auto_number",
              "link",
              "formula",
              "created_at",
              "updated_at",
              "created_by",
              "updated_by"
            ]
          },
          config: %Schema{type: :object, additionalProperties: true},
          is_primary: %Schema{type: :boolean},
          version: %Schema{type: :integer},
          clear_invalid: %Schema{type: :boolean}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule FieldUpdate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFieldUpdate",
        allOf: [AnkoleWeb.Schemas.PodDatabase.FieldWrite],
        type: :object,
        properties: %{version: %Schema{type: :integer}},
        required: [:version]
      },
      struct?: false
    )
  end

  defmodule View do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodView",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          table_id: %Schema{type: :string},
          name: %Schema{type: :string},
          position: %Schema{type: :string},
          type: %Schema{
            type: :string,
            enum: ["grid", "kanban", "gallery"]
          },
          config: %Schema{type: :object, additionalProperties: true},
          version: %Schema{type: :integer}
        },
        required: [:id, :table_id, :name, :position, :type, :config, :version],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ViewResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodViewResult",
        type: :object,
        properties: %{view: AnkoleWeb.Schemas.PodDatabase.View},
        required: [:view],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ViewWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodViewWrite",
        type: :object,
        properties: %{
          name: %Schema{type: :string},
          position: %Schema{type: :string},
          type: %Schema{
            type: :string,
            enum: ["grid", "kanban", "gallery"]
          },
          config: %Schema{type: :object, additionalProperties: true},
          version: %Schema{type: :integer}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule ViewUpdate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodViewUpdate",
        allOf: [AnkoleWeb.Schemas.PodDatabase.ViewWrite],
        type: :object,
        properties: %{version: %Schema{type: :integer}},
        required: [:version]
      },
      struct?: false
    )
  end

  defmodule DeleteVersion do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodDeleteVersion",
        type: :object,
        properties: %{version: %Schema{type: :integer}},
        required: [:version],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Limits do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodDatabaseLimits",
        type: :object,
        properties: %{
          local_rows: %Schema{type: :integer},
          local_bytes: %Schema{type: :integer},
          query_rows: %Schema{type: :integer},
          record_bytes: %Schema{type: :integer},
          group_count: %Schema{type: :integer},
          statement_timeout_ms: %Schema{type: :integer}
        },
        required: [
          :local_rows,
          :local_bytes,
          :query_rows,
          :record_bytes,
          :group_count,
          :statement_timeout_ms
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule TableSchema do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodTableSchema",
        type: :object,
        properties: %{
          table: AnkoleWeb.Schemas.PodDatabase.Table,
          fields: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Field},
          views: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.View},
          mode: %Schema{type: :string, enum: ["local", "remote"]},
          timezone: %Schema{type: :string},
          limits: AnkoleWeb.Schemas.PodDatabase.Limits,
          local_query: %Schema{
            type: :object,
            properties: %{
              text_contains_ascii: %Schema{type: :boolean},
              jsonb_compare: %Schema{type: :boolean}
            },
            required: [:text_contains_ascii, :jsonb_compare],
            additionalProperties: false
          }
        },
        required: [
          :table,
          :fields,
          :views,
          :mode,
          :timezone,
          :limits,
          :local_query
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Condition do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodCondition",
        type: :object,
        properties: %{
          field_id: %Schema{type: :string},
          operator: %Schema{
            type: :string,
            enum: [
              "is",
              "contains",
              "is_empty",
              "is_not_empty",
              "gt",
              "gte",
              "lt",
              "lte",
              "text_contains"
            ]
          },
          value: AnkoleWeb.Schemas.PodDatabase.Value
        },
        required: [:field_id, :operator],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Filter do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodFilter",
        type: :object,
        properties: %{
          conjunction: %Schema{type: :string, enum: ["and", "or"]},
          conditions: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Condition}
        },
        required: [:conjunction, :conditions],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Sort do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodSort",
        type: :object,
        properties: %{
          field_id: %Schema{type: :string},
          direction: %Schema{type: :string, enum: ["asc", "desc"]}
        },
        required: [:field_id, :direction],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Group do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodGroup",
        type: :object,
        properties: %{
          field_id: %Schema{type: :string},
          value: AnkoleWeb.Schemas.PodDatabase.Value,
          value_json: %Schema{type: :string, nullable: true}
        },
        required: [:field_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule RecordQuery do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRecordQuery",
        type: :object,
        properties: %{
          filter: AnkoleWeb.Schemas.PodDatabase.Filter,
          sort: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Sort},
          group: AnkoleWeb.Schemas.PodDatabase.Group,
          page_size: %Schema{type: :integer},
          page_token: %Schema{type: :string},
          ids: %Schema{type: :array, items: %Schema{type: :string}},
          local: %Schema{type: :boolean}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Record do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRecord",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          data: %Schema{type: :object, additionalProperties: AnkoleWeb.Schemas.PodDatabase.Value},
          versions: %Schema{type: :object, additionalProperties: %Schema{type: :integer}},
          created_at: %Schema{type: :string},
          updated_at: %Schema{type: :string},
          created_by: %Schema{type: :string},
          updated_by: %Schema{type: :string}
        },
        required: [
          :id,
          :data,
          :versions,
          :created_at,
          :updated_at,
          :created_by,
          :updated_by
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Records do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRecords",
        type: :object,
        properties: %{
          records: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Record},
          data_version: %Schema{type: :integer},
          page_token: %Schema{type: :string, nullable: true},
          complete: %Schema{type: :boolean}
        },
        required: [:records, :data_version, :page_token, :complete],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule RecordCreate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRecordCreate",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          data: %Schema{type: :object, additionalProperties: AnkoleWeb.Schemas.PodDatabase.Value}
        },
        required: [:data],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule RecordUpdate do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRecordUpdate",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          data: %Schema{type: :object, additionalProperties: AnkoleWeb.Schemas.PodDatabase.Value},
          expected_versions: %Schema{type: :object, additionalProperties: %Schema{type: :integer}}
        },
        required: [:id, :data, :expected_versions],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule RecordDelete do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRecordDelete",
        type: :object,
        properties: %{
          id: %Schema{type: :string},
          expected_versions: %Schema{type: :object, additionalProperties: %Schema{type: :integer}}
        },
        required: [:id, :expected_versions],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule RecordWrite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodRecordWrite",
        type: :object,
        properties: %{
          creates: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.RecordCreate},
          updates: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.RecordUpdate},
          deletes: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.RecordDelete}
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule WriteResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodWriteResult",
        type: :object,
        properties: %{
          records: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Record},
          deleted_ids: %Schema{type: :array, items: %Schema{type: :string}},
          data_version: %Schema{type: :integer}
        },
        required: [:records, :deleted_ids, :data_version],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule GroupBy do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodGroupBy",
        type: :object,
        properties: %{
          field_id: %Schema{type: :string},
          bucket: %Schema{type: :string, enum: ["day", "week", "month", "quarter", "year"]}
        },
        required: [:field_id],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Metric do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodMetric",
        type: :object,
        properties: %{
          operation: %Schema{type: :string, enum: ["count", "sum", "avg", "min", "max"]},
          field_id: %Schema{type: :string},
          alias: %Schema{type: :string}
        },
        required: [:operation, :alias],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AggregateQuery do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodAggregateQuery",
        type: :object,
        properties: %{
          filter: AnkoleWeb.Schemas.PodDatabase.Filter,
          group_by: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.GroupBy},
          metrics: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Metric}
        },
        required: [:metrics],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AggregateGroup do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodAggregateGroup",
        type: :object,
        properties: %{
          values: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.Value},
          value_json: %Schema{type: :array, items: %Schema{type: :string, nullable: true}},
          metrics: %Schema{
            type: :object,
            additionalProperties: AnkoleWeb.Schemas.PodDatabase.Value
          }
        },
        required: [:values, :metrics],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AggregateResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodAggregateResult",
        type: :object,
        properties: %{
          groups: %Schema{type: :array, items: AnkoleWeb.Schemas.PodDatabase.AggregateGroup},
          data_version: %Schema{type: :integer}
        },
        required: [:groups, :data_version],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule CopyRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodCopyRequest",
        type: :object,
        properties: %{
          parent_id: %Schema{type: :string, nullable: true},
          private_owner_uid: %Schema{type: :string, nullable: true},
          title: %Schema{type: :string},
          filter: AnkoleWeb.Schemas.PodDatabase.Filter
        },
        required: [],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule CopyResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(
      %{
        title: "PodCopyResult",
        type: :object,
        properties: %{
          page: AnkoleWeb.Schemas.PodContent.Page,
          table: AnkoleWeb.Schemas.PodDatabase.Table
        },
        required: [:page, :table],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
