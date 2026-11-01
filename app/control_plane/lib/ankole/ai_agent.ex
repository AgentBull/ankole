defmodule Ankole.AIAgent do
  @moduledoc """
  The Ash domain of the Agent library: Skill rows, lessons, persona documents,
  Agent Plugin overrides, and Console operations.

  Other domains read the rows through these defines. The library writes go
  through `Ankole.AIAgent.Library`, `Ankole.AIGateway.ModelProfiles`, and
  `Ankole.AIAgent.TokenQuota`.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource(Ankole.AIAgent.Library.AgentPlugins.Schemas.AgentPluginOverride)
    resource(Ankole.AIAgent.Library.Schemas.AgentLibraryContainerEntry)

    resource Ankole.AIAgent.Library.Schemas.AgentSkill do
      define(:list_agent_skills, action: :read)
    end

    resource Ankole.AIAgent.Library.Schemas.AgentSkillLesson do
      define(:list_agent_skill_lessons, action: :read)
    end

    resource(Ankole.AIAgent.Console)
    resource(Ankole.AIAgent.Library.Console)
  end

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/agent-library", Ankole.AIAgent.Library.Console do
        route(:get, "/capabilities", :global_capabilities,
          name: "get_global_library_capabilities",
          wrap_in_result?: false
        )

        route(:put, "/agent-plugins/:id", :set_global_plugin,
          name: "set_global_library_plugin",
          wrap_in_result?: false
        )

        route(:put, "/skills/:id", :set_global_skill,
          name: "set_global_library_skill",
          wrap_in_result?: false
        )
      end

      base_route "/agents/:agent_uid", Ankole.AIAgent.Library.Console do
        route(:get, "/library-capabilities", :agent_capabilities,
          name: "get_agent_library_capabilities",
          wrap_in_result?: false
        )

        route(:put, "/library-capabilities/agent-plugins/:id", :set_agent_plugin,
          name: "set_agent_library_plugin",
          wrap_in_result?: false
        )

        route(:put, "/library-capabilities/skills/:id", :set_agent_skill,
          name: "set_agent_library_skill",
          wrap_in_result?: false
        )

        route(:get, "/library-documents", :documents,
          name: "list_agent_library_documents",
          wrap_in_result?: false
        )

        route(:put, "/library-documents/:document_kind", :replace_document,
          name: "replace_agent_library_document",
          wrap_in_result?: false
        )
      end

      base_route "/model-profiles", Ankole.AIAgent.Console do
        route(:get, "/", :defaults_model_profiles, name: "list_default_model_profiles")

        route(:put, "/provider-hosted", :put_default_provider_hosted,
          name: "put_default_provider_hosted"
        )

        route(:put, "/:profile", :put_default_model_profile, name: "put_default_model_profile")

        route(:delete, "/:profile", :delete_default_model_profile,
          name: "delete_default_model_profile",
          query_params: [:defaults_scope]
        )
      end

      base_route "/system-principals", Ankole.AIAgent.Console do
        route(:get, "/", :system_principals, name: "list_system_principals")

        route(:get, "/:uid/model-profiles", :system_model_profiles,
          name: "list_system_model_profiles"
        )

        route(:put, "/:uid/model-profiles/:profile", :put_system_model_profile,
          name: "put_system_model_profile"
        )

        route(:delete, "/:uid/model-profiles/:profile", :delete_system_model_profile,
          name: "delete_system_model_profile"
        )
      end

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
