defmodule Ankole.AIAgent do
  @moduledoc """
  The Ash domain of the Agent library: Skill rows, lessons, persona documents,
  and Agent Plugin overrides.

  Other domains read the rows through these defines. The library writes go
  through `Ankole.AIAgent.Library`, `Ankole.AIAgent.ModelProfiles`, and
  `Ankole.AIAgent.TokenQuota`, which run the generic actions of the
  resources.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

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
    resource(Ankole.AIAgent.Console)
  end

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/agents/:agent_uid", Ankole.AIAgent.Console do
        route(:get, "/model-profiles", :model_profiles, name: "list_agent_model_profiles")

        route(:put, "/model-profiles/:profile", :put_model_profile,
          name: "put_agent_model_profile"
        )

        route(:delete, "/model-profiles/:profile", :delete_model_profile,
          name: "delete_agent_model_profile"
        )

        route(:put, "/provider-hosted", :put_provider_hosted, name: "put_agent_provider_hosted")
        route(:get, "/token-quota", :token_quota, name: "get_agent_token_quota")
        route(:put, "/token-quota", :put_token_quota, name: "put_agent_token_quota")
        route(:delete, "/token-quota", :delete_token_quota, name: "delete_agent_token_quota")
        route(:post, "/token-quota/reset", :reset_token_quota, name: "reset_agent_token_quota")
      end

      base_route "/agents/:agent_uid/skill-lessons",
                 Ankole.AIAgent.Library.Schemas.AgentSkillLesson do
        index(:console_list, name: "list_agent_skill_lessons", derive_sort?: false)
        route(:post, "/", :console_teach, name: "create_agent_skill_lesson")
        route(:post, "/:lesson_id/retire", :revoke, name: "retire_agent_skill_lesson")
      end
    end
  end
end
