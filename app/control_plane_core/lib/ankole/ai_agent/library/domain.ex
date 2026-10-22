defmodule Ankole.AIAgent.Library.Domain do
  @moduledoc "Durable Agent library registry, documents, overrides, and lessons."
  use Ash.Domain

  resources do
    resource(Ankole.AIAgent.Library.AgentPlugins.Schemas.AgentPluginOverride)
    resource(Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry)
    resource(Ankole.AIAgent.Library.Schemas.AgentSkill)
    resource(Ankole.AIAgent.Library.Schemas.AgentSkillLesson)
  end
end
