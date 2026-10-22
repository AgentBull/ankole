defmodule Ankole.AIAgent do
  @moduledoc """
  The Ash domain of the Agent library: Skill rows, lessons, persona documents,
  and Agent Plugin overrides.

  Other domains read the rows through these defines. The library writes go
  through `Ankole.AIAgent.Library`, `Ankole.AIAgent.ModelProfiles`, and
  `Ankole.AIAgent.TokenQuota`, which run the generic actions of the
  resources.
  """
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AIAgent.Library.AgentPlugins.Schemas.AgentPluginOverride do
      define(:get_agent_plugin_override, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_plugin_overrides, action: :read)
    end

    resource Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry do
      define(:get_agent_library_container_entry,
        action: :read,
        get_by: [:id],
        not_found_error?: false
      )

      define(:list_agent_library_container_entries, action: :read)
    end

    resource Ankole.AIAgent.Library.Schemas.AgentSkill do
      define(:get_agent_skill, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_skills, action: :read)
    end

    resource Ankole.AIAgent.Library.Schemas.AgentSkillLesson do
      define(:get_agent_skill_lesson, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_skill_lessons, action: :read)
    end

    resource(Ankole.AIAgent.Operations)
  end
end
