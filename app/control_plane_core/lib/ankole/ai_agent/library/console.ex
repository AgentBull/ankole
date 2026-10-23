defmodule Ankole.AIAgent.Library.Console do
  @moduledoc "Console operations for Agent Library capabilities and documents."
  use Ash.Resource,
    domain: Ankole.AIAgent.Library,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("agent_library_console")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :global_capabilities,
           Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryCapabilitiesResponse do
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :set_global_plugin,
           Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryCapabilitiesResponse do
      transaction?(false)
      argument(:id, :string, allow_nil?: false)
      argument(:enabled, :boolean, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :set_global_skill,
           Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryCapabilitiesResponse do
      transaction?(false)
      argument(:id, :string, allow_nil?: false)
      argument(:enabled, :boolean, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :agent_capabilities,
           Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryCapabilitiesResponse do
      transaction?(false)
      argument(:agent_uid, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :set_agent_plugin,
           Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryCapabilitiesResponse do
      transaction?(false)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:id, :string, allow_nil?: false)
      argument(:enabled, :boolean)
      run(__MODULE__.Actions)
    end

    action :set_agent_skill,
           Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryCapabilitiesResponse do
      transaction?(false)
      argument(:agent_uid, :string, allow_nil?: false)
      argument(:id, :string, allow_nil?: false)
      argument(:enabled, :boolean)
      run(__MODULE__.Actions)
    end

    action :documents, Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentsResponse do
      transaction?(false)
      argument(:agent_uid, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end

    action :replace_document, Ankole.AIAgent.Library.ConsoleTypes.AgentLibraryDocumentResponse do
      transaction?(false)
      argument(:agent_uid, :string, allow_nil?: false)

      argument(:document_kind, :string, allow_nil?: false)

      argument(:content, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:expected_content_hash, :string, allow_nil?: false)
      run(__MODULE__.Actions)
    end
  end
end
