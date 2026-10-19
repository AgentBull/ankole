defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentComputerWorkerItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentComputerWorkerItem",
      type: :object,
      properties: %{
        agent_uid: %Schema{type: :string},
        provider_id: %Schema{type: :string, nullable: true},
        state: %Schema{
          type: :string,
          enum: ["absent", "starting", "ready", "stale", "paused", "draining", "deleting"]
        },
        generation: %Schema{type: :string, nullable: true},
        image: %Schema{type: :string, nullable: true},
        capacity: %Schema{type: :object, additionalProperties: true},
        load: %Schema{type: :object, additionalProperties: true},
        last_worker_heartbeat_at: %Schema{type: :string, nullable: true},
        state_changed_at: %Schema{type: :string, nullable: true},
        drain_reason: %Schema{type: :string, nullable: true},
        last_error: %Schema{type: :string, nullable: true}
      },
      required: [:agent_uid, :state, :capacity, :load],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessProvider do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConsoleReadinessProvider",
      type: :object,
      properties: %{
        complete: %Schema{type: :boolean},
        provider_id: %Schema{type: :string, nullable: true}
      },
      required: [:complete, :provider_id],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessAgent do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConsoleReadinessAgent",
      type: :object,
      properties: %{
        complete: %Schema{type: :boolean},
        uid: %Schema{type: :string, nullable: true},
        display_name: %Schema{type: :string, nullable: true}
      },
      required: [:complete, :uid, :display_name],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessModelProfiles do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConsoleReadinessModelProfiles",
      type: :object,
      properties: %{
        complete: %Schema{type: :boolean},
        agent_uid: %Schema{type: :string, nullable: true},
        missing_profiles: %Schema{type: :array, items: %Schema{type: :string}}
      },
      required: [:complete, :agent_uid, :missing_profiles],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessWorker do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConsoleReadinessWorker",
      type: :object,
      properties: %{
        complete: %Schema{type: :boolean},
        ready_count: %Schema{type: :integer, minimum: 0}
      },
      required: [:complete, :ready_count],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessSignalRoute do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConsoleReadinessSignalRoute",
      type: :object,
      properties: %{
        complete: %Schema{type: :boolean}
      },
      required: [:complete],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessAgent
  alias AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessModelProfiles
  alias AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessProvider
  alias AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessSignalRoute
  alias AnkoleWeb.Schemas.ConsoleAPI.ConsoleReadinessWorker

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "ConsoleReadinessResponse",
      type: :object,
      properties: %{
        ready: %Schema{type: :boolean},
        completed_core_steps: %Schema{type: :integer, minimum: 0},
        total_core_steps: %Schema{type: :integer, minimum: 1},
        provider: ConsoleReadinessProvider,
        agent: ConsoleReadinessAgent,
        model_profiles: ConsoleReadinessModelProfiles,
        worker: ConsoleReadinessWorker,
        signal_route: ConsoleReadinessSignalRoute
      },
      required: [
        :ready,
        :completed_core_steps,
        :total_core_steps,
        :provider,
        :agent,
        :model_profiles,
        :worker,
        :signal_route
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentComputerWorkerListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentComputerWorkerItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentComputerWorkerListResponse",
      type: :object,
      properties: %{
        workers: %Schema{type: :array, items: AgentComputerWorkerItem}
      },
      required: [:workers],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileEntry do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileEntry",
      type: :object,
      properties: %{
        path: %Schema{type: :string},
        size: %Schema{type: :integer},
        content_type: %Schema{type: :string},
        source: %Schema{
          type: :string,
          enum: Ankole.Files.Schemas.DriveFile.sources()
        },
        conversation_id: %Schema{type: :string, nullable: true},
        message_id: %Schema{type: :string, format: :uuid, nullable: true},
        updated_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [
        :path,
        :size,
        :content_type,
        :source,
        :conversation_id,
        :message_id,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileFolder do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileFolder",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        path: %Schema{type: :string}
      },
      required: [:name, :path],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileEntry
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileFolder

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileListResponse",
      type: :object,
      properties: %{
        file_listing: %Schema{
          type: :object,
          properties: %{
            path: %Schema{type: :string},
            folders: %Schema{type: :array, items: AgentFileFolder},
            files: %Schema{type: :array, items: AgentFileEntry},
            truncated: %Schema{
              type: :boolean,
              description: "True when the folder has more folders or files than the listing shows"
            }
          },
          required: [:path, :folders, :files, :truncated],
          additionalProperties: false
        }
      },
      required: [:file_listing],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileUploadRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileUploadRequest",
      type: :object,
      properties: %{
        path: %Schema{type: :string},
        file: %Schema{type: :string, format: :binary}
      },
      required: [:path, :file],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileUploadResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileEntry

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileUploadResponse",
      type: :object,
      properties: %{uploaded_file: AgentFileEntry},
      required: [:uploaded_file],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileMoveRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileMoveRequest",
      type: :object,
      properties: %{
        from_path: %Schema{type: :string},
        to_path: %Schema{type: :string}
      },
      required: [:from_path, :to_path],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileMoveResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileMoveResponse",
      type: :object,
      properties: %{moved_files: %Schema{type: :integer}},
      required: [:moved_files],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentFileDeleteResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentFileDeleteResponse",
      type: :object,
      properties: %{deleted_files: %Schema{type: :integer}},
      required: [:deleted_files],
      additionalProperties: false
    },
    struct?: false
  )
end
