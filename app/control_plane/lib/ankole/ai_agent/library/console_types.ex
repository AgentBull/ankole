defmodule Ankole.AIAgent.Library.ConsoleTypes.AgentLibrarySkillCapabilityItem do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        agent_plugin_id: [type: :string, allow_nil?: true],
        description: [type: :string, allow_nil?: false],
        effective_enabled: [type: :boolean, allow_nil?: false],
        global_default_enabled: [type: :boolean, allow_nil?: false],
        id: [type: :string, allow_nil?: false],
        name: [type: :string, allow_nil?: false],
        override_enabled: [type: :boolean, allow_nil?: true],
        source_kind: [type: :string, allow_nil?: false]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.AIAgent.Library.ConsoleTypes.AgentPluginCapabilityItem do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        description: [type: :string, allow_nil?: false],
        effective_enabled: [type: :boolean, allow_nil?: false],
        global_default_enabled: [type: :boolean, allow_nil?: false],
        id: [type: :string, allow_nil?: false],
        override_enabled: [type: :boolean, allow_nil?: true],
        skills: [
          type: {:array, Ankole.AIAgent.Library.ConsoleTypes.AgentLibrarySkillCapabilityItem},
          allow_nil?: false
        ],
        version: [type: :string, allow_nil?: false]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryCapabilitiesResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        agent_plugins: [
          type: {:array, Ankole.AIAgent.Library.ConsoleTypes.AgentPluginCapabilityItem},
          allow_nil?: false
        ],
        skills: [
          type: {:array, Ankole.AIAgent.Library.ConsoleTypes.AgentLibrarySkillCapabilityItem},
          allow_nil?: false
        ]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentItem do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        content: [type: :string, allow_nil?: false],
        content_hash: [type: :string, allow_nil?: false],
        kind: [type: :string, allow_nil?: false]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocuments do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        confidentiality_policy: [
          type: Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentItem,
          allow_nil?: false
        ],
        design: [
          type: Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentItem,
          allow_nil?: false
        ],
        mission: [
          type: Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentItem,
          allow_nil?: false
        ],
        soul: [
          type: Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentItem,
          allow_nil?: false
        ]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentsResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        library_documents: [
          type: Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocuments,
          allow_nil?: false
        ]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        library_document: [
          type: Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentItem,
          allow_nil?: false
        ]
      ],
      preserve_nil_values?: true
    ]
end
