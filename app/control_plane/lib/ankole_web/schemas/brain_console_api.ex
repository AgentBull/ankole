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
          kind: %Schema{
            type: :string,
            enum: ["retained_source", "signal_message"]
          },
          capture_method: %Schema{
            type: :string,
            nullable: true
          },
          title: %Schema{type: :string},
          store_key: %Schema{type: :string},
          origin_locator: %Schema{type: :string, nullable: true},
          connector_id: %Schema{type: :string, nullable: true},
          revision: %Schema{type: :string, nullable: true},
          source_url: %Schema{type: :string, nullable: true},
          sync_state: %Schema{
            type: :string,
            enum: ["current", "deleted", "access_lost", "failed"],
            nullable: true
          },
          last_synced_at: %Schema{type: :string, format: :date_time, nullable: true},
          original_name: %Schema{type: :string, nullable: true},
          media_type: %Schema{type: :string},
          byte_size: %Schema{type: :integer, nullable: true},
          sha256: %Schema{type: :string, nullable: true},
          text: %Schema{type: :string, nullable: true},
          captured_by_uid: %Schema{type: :string, nullable: true},
          captured_at: %Schema{type: :string, format: :date_time, nullable: true},
          learning_status: %Schema{
            type: :string,
            enum: ["stored", "learning", "integrated", "no_change", "incomplete", "failed"],
            nullable: true
          },
          learning_actor_event_id: %Schema{type: :string, format: :uuid, nullable: true},
          integrated_entries: %Schema{
            type: :array,
            items: %Schema{
              type: :object,
              properties: %{
                id: %Schema{type: :string, format: :uuid},
                name: %Schema{type: :string},
                type: %Schema{type: :string},
                store_key: %Schema{type: :string}
              },
              required: [:id, :name, :type, :store_key],
              additionalProperties: false
            }
          },
          signal_channel_id: %Schema{type: :string, nullable: true},
          source_entry_id: %Schema{type: :string, nullable: true},
          rich_content: %Schema{type: :object, additionalProperties: true, nullable: true},
          attachments: %Schema{type: :array, items: JSONValue},
          links: %Schema{type: :array, items: JSONValue},
          author: %Schema{type: :object, additionalProperties: true},
          metadata: %Schema{type: :object, additionalProperties: true}
        },
        required: [
          :document_id,
          :kind,
          :title,
          :store_key,
          :media_type,
          :integrated_entries
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule Citation do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainCitation",
        type: :object,
        properties: %{
          block_id: %Schema{type: :string, format: :uuid},
          document_id: %Schema{type: :string},
          source_kind: %Schema{type: :string, enum: ["signal_message", "retained_source"]}
        },
        required: [:block_id, :document_id, :source_kind],
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
              "set_aliases",
              "set_name",
              "set_type"
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
          initial_body: %Schema{type: :string},
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
          citations: %Schema{type: :array, items: Citation},
          relations: %Schema{type: :array, items: Relation},
          backlinks: %Schema{type: :array, items: Relation},
          markdown: %Schema{type: :string}
        },
        required: [:entry, :blocks, :citations, :relations, :backlinks, :markdown],
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
          operations: %Schema{type: :array, items: EntryOperation, minItems: 1},
          reason: %Schema{
            type: :string,
            description: "Optional human reason retained in each audit record in this batch"
          }
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

  defmodule SourceListResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainSourceListResponse",
        type: :object,
        properties: %{sources: %Schema{type: :array, items: SourceEntry}},
        required: [:sources],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SourceCaptureResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainSourceCaptureResponse",
        type: :object,
        properties: %{
          resource_kind: %Schema{type: :string, enum: ["entry", "retained_source"]},
          entry: EntryResponse,
          source: SourceEntry
        },
        required: [:resource_kind],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule StatusResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainStatusResponse",
        type: :object,
        properties: %{
          memory_status: JSONValue
        },
        required: [:memory_status],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule SourceCaptureRequest do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainSourceCaptureRequest",
        type: :object,
        properties: %{
          kind: %Schema{type: :string, enum: ["paste", "url", "file"]},
          title: %Schema{type: :string},
          content: %Schema{type: :string},
          url: %Schema{type: :string},
          file: %Schema{type: :string, format: :binary}
        },
        required: [:kind],
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

  defmodule DreamingFitnessRun do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainDreamingFitnessRun",
        type: :object,
        description: "One dreaming run's block writes and how they fared under human review.",
        properties: %{
          run_id: %Schema{type: :string, format: :uuid, nullable: true},
          produced_block_writes: %Schema{type: :integer, minimum: 0},
          matured_block_writes: %Schema{type: :integer, minimum: 0},
          pending_block_writes: %Schema{type: :integer, minimum: 0},
          corrected_block_writes: %Schema{type: :integer, minimum: 0},
          survived_block_writes: %Schema{type: :integer, minimum: 0},
          survival_rate: %Schema{type: :number, minimum: 0, maximum: 1, nullable: true},
          first_written_at: %Schema{type: :string, format: :date_time, nullable: true},
          last_written_at: %Schema{type: :string, format: :date_time, nullable: true}
        },
        required: [
          :produced_block_writes,
          :matured_block_writes,
          :pending_block_writes,
          :corrected_block_writes,
          :survived_block_writes
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DreamingFitness do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainDreamingFitness",
        type: :object,
        description:
          "Share of dreaming block writes that survived human review, overall and per run. Survival is judged only on writes older than the horizon; younger writes are pending.",
        properties: %{
          horizon_days: %Schema{type: :integer, minimum: 1},
          lookback_days: %Schema{type: :integer, minimum: 1},
          generated_at: %Schema{type: :string, format: :date_time},
          produced_block_writes: %Schema{type: :integer, minimum: 0},
          matured_block_writes: %Schema{type: :integer, minimum: 0},
          pending_block_writes: %Schema{type: :integer, minimum: 0},
          corrected_block_writes: %Schema{type: :integer, minimum: 0},
          survived_block_writes: %Schema{type: :integer, minimum: 0},
          survival_rate: %Schema{type: :number, minimum: 0, maximum: 1, nullable: true},
          runs: %Schema{type: :array, items: DreamingFitnessRun}
        },
        required: [
          :horizon_days,
          :lookback_days,
          :generated_at,
          :produced_block_writes,
          :matured_block_writes,
          :pending_block_writes,
          :corrected_block_writes,
          :survived_block_writes,
          :runs
        ],
        additionalProperties: false
      },
      struct?: false
    )
  end

  defmodule DreamingFitnessResponse do
    @moduledoc false

    require OpenAPISpex

    OpenAPISpex.schema(
      %{
        title: "BrainDreamingFitnessResponse",
        type: :object,
        properties: %{fitness: DreamingFitness},
        required: [:fitness],
        additionalProperties: false
      },
      struct?: false
    )
  end
end
