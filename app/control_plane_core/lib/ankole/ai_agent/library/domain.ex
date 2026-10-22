defmodule Ankole.AIAgent.Library.Domain do
  @moduledoc "Durable Agent library registry, documents, overrides, and lessons."
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AIAgent.Library.AgentPlugins.Schemas.AgentPluginOverride do
      define(:get_agent_plugin_override, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_plugin_overrides, action: :read)
      define(:set_agent_plugin_override, action: :set)
      define(:reset_agent_plugin_override, action: :reset)
    end

    resource Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry do
      define(:get_agent_library_container_entry,
        action: :read,
        get_by: [:id],
        not_found_error?: false
      )

      define(:list_agent_library_container_entries, action: :read)
      define(:put_agent_library_container_entry, action: :put)
    end

    resource Ankole.AIAgent.Library.Schemas.AgentSkill do
      define(:get_agent_skill, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_skills, action: :read)
      define(:sync_agent_skill, action: :sync)
      define(:set_override_agent_skill, action: :set_override)
      define(:remove_stale_agent_skill, action: :remove_stale)
    end

    resource Ankole.AIAgent.Library.Schemas.AgentSkillLesson do
      define(:get_agent_skill_lesson, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_agent_skill_lessons, action: :read)
      define(:teach_human_agent_skill_lesson, action: :teach_human)
      define(:teach_dreaming_agent_skill_lesson, action: :teach_dreaming)
      define(:renew_agent_skill_lesson, action: :renew)
      define(:retire_agent_skill_lesson, action: :retire)
    end
  end
end
