defmodule AnkoleWeb.Schemas.BrainConsoleAPI do
  @moduledoc "OpenAPI schemas for the Brain human-supervision console."

  alias AnkoleWeb.Schemas.ConsoleAPI.JSONValue
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  defmodule Entry do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntry",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          owner_uid: %Schema{type: :string},
          store_key: %Schema{type: :string},
          name: %Schema{type: :string},
          type: %Schema{type: :string},
          summary: %Schema{type: :string},
          aliases: %Schema{type: :array, items: %Schema{type: :string}},
          properties: %Schema{type: :object, additionalProperties: true},
          lock_version: %Schema{type: :integer, minimum: 1},
          inserted_at: %Schema{type: :string, format: :date_time},
          updated_at: %Schema{type: :string, format: :date_time}
        },
        required: [
          :id,
          :owner_uid,
          :store_key,
          :name,
          :type,
          :summary,
          :aliases,
          :properties,
          :lock_version,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Block do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntryBlock",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          entry_id: %Schema{type: :string, format: :uuid},
          position: %Schema{type: :integer, minimum: 0},
          body: %Schema{type: :string},
          author_kind: %Schema{
            type: :string,
            enum: ["human", "agent", "dreaming"]
          },
          author_uid: %Schema{type: :string, nullable: true},
          embedding_state: %Schema{type: :string, enum: ["pending", "synced", "failed"]},
          embedding_error: %Schema{type: :string, nullable: true},
          lock_version: %Schema{type: :integer, minimum: 1},
          inserted_at: %Schema{type: :string, format: :date_time},
          updated_at: %Schema{type: :string, format: :date_time}
        },
        required: [
          :id,
          :entry_id,
          :position,
          :body,
          :author_kind,
          :embedding_state,
          :lock_version,
          :inserted_at,
          :updated_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Relation do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntryRelation",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          source_entry_id: %Schema{type: :string, format: :uuid},
          source_name: %Schema{type: :string, nullable: true},
          predicate: %Schema{type: :string},
          target_entry_id: %Schema{type: :string, format: :uuid},
          target_name: %Schema{type: :string, nullable: true},
          inserted_at: %Schema{type: :string, format: :date_time}
        },
        required: [:id, :source_entry_id, :predicate, :target_entry_id, :inserted_at],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AuditLog do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainAuditLog",
        type: :object,
        properties: %{
          id: %Schema{type: :string, format: :uuid},
          owner_uid: %Schema{type: :string},
          store_key: %Schema{type: :string},
          actor_kind: %Schema{
            type: :string,
            enum: ["human", "agent", "dreaming"],
            nullable: true
          },
          actor_uid: %Schema{type: :string, nullable: true},
          action: %Schema{type: :string},
          entry_id: %Schema{type: :string, format: :uuid, nullable: true},
          block_id: %Schema{type: :string, format: :uuid, nullable: true},
          relation_id: %Schema{type: :string, format: :uuid, nullable: true},
          before: %Schema{type: :object, additionalProperties: true, nullable: true},
          after: %Schema{type: :object, additionalProperties: true, nullable: true},
          metadata: %Schema{type: :object, additionalProperties: true},
          inserted_at: %Schema{type: :string, format: :date_time}
        },
        required: [
          :id,
          :owner_uid,
          :store_key,
          :action,
          :metadata,
          :inserted_at
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SourceEntry do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainSourceEntry",
        type: :object,
        properties: %{
          document_id: %Schema{type: :string},
          signal_channel_id: %Schema{type: :string},
          source_entry_id: %Schema{type: :string},
          text: %Schema{type: :string, nullable: true},
          formatted_content: %Schema{type: :object, additionalProperties: true},
          attachments: %Schema{type: :array, items: JSONValue},
          links: %Schema{type: :array, items: JSONValue},
          author: %Schema{type: :object, additionalProperties: true},
          metadata: %Schema{type: :object, additionalProperties: true},
          provider_time: %Schema{type: :string, format: :date_time, nullable: true}
        },
        required: [
          :document_id,
          :signal_channel_id,
          :source_entry_id,
          :formatted_content,
          :attachments,
          :links,
          :author,
          :metadata
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule EntryOperation do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntryOperation",
        type: :object,
        description:
          "One structured Brain mutation. owner/store/author are intentionally absent and are derived by the server.",
        properties: %{
          operation: %Schema{
            type: :string,
            enum: [
              "create_entry",
              "delete_entry",
              "append_block",
              "edit_block",
              "delete_block",
              "set_property",
              "add_relation",
              "remove_relation",
              "set_summary",
              "set_aliases"
            ]
          },
          entry_id: %Schema{type: :string, format: :uuid},
          block_id: %Schema{type: :string, format: :uuid},
          relation_id: %Schema{type: :string, format: :uuid},
          target_entry_id: %Schema{type: :string, format: :uuid},
          name: %Schema{type: :string},
          type: %Schema{type: :string},
          summary: %Schema{type: :string},
          aliases: %Schema{type: :array, items: %Schema{type: :string}},
          properties: %Schema{type: :object, additionalProperties: true},
          body: %Schema{type: :string},
          key: %Schema{type: :string},
          value: JSONValue,
          predicate: %Schema{type: :string},
          expected_entry_lock_version: %Schema{type: :integer, minimum: 1},
          expected_block_lock_version: %Schema{type: :integer, minimum: 1}
        },
        required: [:operation],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule EntryListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntryListResponse",
        type: :object,
        properties: %{
          entries: %Schema{type: :array, items: Entry},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:entries],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule EntryResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntryResponse",
        type: :object,
        properties: %{
          entry: Entry,
          blocks: %Schema{type: :array, items: Block},
          relations: %Schema{type: :array, items: Relation},
          backlinks: %Schema{type: :array, items: Relation},
          markdown: %Schema{type: :string}
        },
        required: [:entry, :blocks, :relations, :backlinks, :markdown],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule EntryOperationsRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntryOperationsRequest",
        type: :object,
        properties: %{
          operations: %Schema{type: :array, items: EntryOperation, minItems: 1}
        },
        required: [:operations],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule EntryOperationsResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainEntryOperationsResponse",
        type: :object,
        properties: %{
          results: %Schema{type: :array, items: JSONValue},
          touched_entry_ids: %Schema{
            type: :array,
            items: %Schema{type: :string, format: :uuid}
          }
        },
        required: [:results, :touched_entry_ids],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AuditLogResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainAuditLogResponse",
        type: :object,
        properties: %{
          audit_log: %Schema{type: :array, items: AuditLog},
          next_cursor: %Schema{type: :string, nullable: true}
        },
        required: [:audit_log],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SourceEntryResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainSourceEntryResponse",
        type: :object,
        properties: %{source: SourceEntry},
        required: [:source],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AuditRestorationResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainAuditRestorationResponse",
        type: :object,
        properties: %{restoration: JSONValue},
        required: [:restoration],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule AuditRestorationsRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainAuditRestorationsRequest",
        type: :object,
        properties: %{
          audit_ids: %Schema{
            type: :array,
            items: %Schema{type: :string, format: :uuid},
            minItems: 1,
            maxItems: 10_000
          }
        },
        required: [:audit_ids],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DreamingRun do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainDreamingRun",
        type: :object,
        properties: %{
          status: %Schema{
            type: :string,
            enum: ["completed", "no_new_material", "already_running", "disabled"]
          },
          material_count: %Schema{type: :integer, minimum: 0},
          operation_count: %Schema{type: :integer, minimum: 0},
          skill_update_count: %Schema{type: :integer, minimum: 0},
          touched_entry_ids: %Schema{
            type: :array,
            items: %Schema{type: :string, format: :uuid}
          },
          run_id: %Schema{type: :string, format: :uuid}
        },
        required: [:status],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DreamingRunResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainDreamingRunResponse",
        type: :object,
        properties: %{run: DreamingRun},
        required: [:run],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
