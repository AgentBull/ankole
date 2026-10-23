defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.ActorRef

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentItem",
      type: :object,
      properties: %{
        uid: %Schema{type: :string},
        handle: %Schema{type: :string},
        worker_provider_id: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: ["active", "disabled"]},
        display_name: %Schema{type: :string},
        avatar_url: %Schema{type: :string, nullable: true},
        type: %Schema{type: :string, enum: ["ai_colleague"]},
        role: %Schema{type: :string},
        options: %Schema{type: :object, additionalProperties: true},
        owner_principal_uid: %Schema{type: :string},
        group_memory_disclosure_mode: %Schema{type: :string, enum: ["strict", "relaxed"]},
        created_by: %Schema{allOf: [ActorRef], nullable: true},
        inserted_at: %Schema{type: :string},
        updated_at: %Schema{type: :string}
      },
      required: [
        :uid,
        :handle,
        :status,
        :display_name,
        :type,
        :role,
        :options,
        :owner_principal_uid,
        :group_memory_disclosure_mode,
        :inserted_at,
        :updated_at
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentListResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentListResponse",
      type: :object,
      properties: %{
        agents: %Schema{type: :array, items: AgentItem}
      },
      required: [:agents],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentResponse",
      type: :object,
      properties: %{
        agent: AgentItem
      },
      required: [:agent],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentCreateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentCreateRequest",
      type: :object,
      properties: %{
        handle: %Schema{type: :string},
        worker_provider_id: %Schema{type: :string, nullable: true},
        display_name: %Schema{type: :string},
        avatar_url: %Schema{type: :string, nullable: true},
        role: %Schema{type: :string},
        options: %Schema{type: :object, additionalProperties: true},
        owner_principal_uid: %Schema{type: :string},
        group_memory_disclosure_mode: %Schema{type: :string, enum: ["strict", "relaxed"]}
      },
      required: [:handle, :display_name, :role, :owner_principal_uid],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentUpdateRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentUpdateRequest",
      type: :object,
      properties: %{
        handle: %Schema{type: :string},
        display_name: %Schema{type: :string},
        avatar_url: %Schema{type: :string, nullable: true},
        role: %Schema{type: :string},
        options: %Schema{type: :object, additionalProperties: true},
        owner_principal_uid: %Schema{type: :string},
        group_memory_disclosure_mode: %Schema{type: :string, enum: ["strict", "relaxed"]}
      },
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryDocumentItem",
      type: :object,
      properties: %{
        kind: %Schema{type: :string, enum: ~w(mission soul design confidentiality_policy)},
        content: %Schema{type: :string},
        content_hash: %Schema{type: :string}
      },
      required: [:kind, :content, :content_hash],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocuments do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryDocuments",
      type: :object,
      properties: %{
        mission: AgentLibraryDocumentItem,
        soul: AgentLibraryDocumentItem,
        design: AgentLibraryDocumentItem,
        confidentiality_policy: AgentLibraryDocumentItem
      },
      required: [:mission, :soul, :design, :confidentiality_policy],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentsResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocuments

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryDocumentsResponse",
      type: :object,
      properties: %{
        library_documents: AgentLibraryDocuments
      },
      required: [:library_documents],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryDocumentResponse",
      type: :object,
      properties: %{
        library_document: AgentLibraryDocumentItem
      },
      required: [:library_document],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryDocumentWriteRequest",
      type: :object,
      properties: %{
        content: %Schema{type: :string},
        expected_content_hash: %Schema{type: :string}
      },
      required: [:content, :expected_content_hash],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibrarySkillCapabilityItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibrarySkillCapabilityItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        name: %Schema{type: :string},
        description: %Schema{type: :string},
        source_kind: %Schema{type: :string, enum: ~w(builtin installed)},
        agent_plugin_id: %Schema{type: :string, nullable: true},
        global_default_enabled: %Schema{type: :boolean},
        override_enabled: %Schema{type: :boolean, nullable: true},
        effective_enabled: %Schema{type: :boolean}
      },
      required: [
        :id,
        :name,
        :description,
        :source_kind,
        :agent_plugin_id,
        :global_default_enabled,
        :override_enabled,
        :effective_enabled
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentPluginCapabilityItem do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibrarySkillCapabilityItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentPluginCapabilityItem",
      type: :object,
      properties: %{
        id: %Schema{type: :string},
        description: %Schema{type: :string},
        version: %Schema{type: :string},
        global_default_enabled: %Schema{type: :boolean},
        override_enabled: %Schema{type: :boolean, nullable: true},
        effective_enabled: %Schema{type: :boolean},
        skills: %Schema{type: :array, items: AgentLibrarySkillCapabilityItem}
      },
      required: [
        :id,
        :description,
        :version,
        :global_default_enabled,
        :override_enabled,
        :effective_enabled,
        :skills
      ],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryCapabilitiesResponse do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibrarySkillCapabilityItem
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentPluginCapabilityItem

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryCapabilitiesResponse",
      type: :object,
      properties: %{
        agent_plugins: %Schema{type: :array, items: AgentPluginCapabilityItem},
        skills: %Schema{type: :array, items: AgentLibrarySkillCapabilityItem}
      },
      required: [:agent_plugins, :skills],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryGlobalDefaultWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryGlobalDefaultWriteRequest",
      type: :object,
      properties: %{enabled: %Schema{type: :boolean}},
      required: [:enabled],
      additionalProperties: false
    },
    struct?: false
  )
end

defmodule AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryAgentOverrideWriteRequest do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Schema

  @moduledoc false

  require OpenAPISpex

  OpenAPISpex.schema(
    %{
      title: "AgentLibraryAgentOverrideWriteRequest",
      type: :object,
      properties: %{enabled: %Schema{type: :boolean, nullable: true}},
      required: [:enabled],
      additionalProperties: false
    },
    struct?: false
  )
end
