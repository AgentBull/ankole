defmodule AnkoleWeb.JSONAPI.Policy do
  @moduledoc """
  Authorizes each JSON:API route through Principal/AuthZ.

  Ash policies stay disabled: Principal/AuthZ is the only authorization model.
  Each route of a JSON:API router has one rule in `@rules`. A rule gives the
  AuthZ resource and action that `AnkoleWeb.ConsolePolicy.authorize/3` checks.
  The AuthZ resource
  can contain `{name}` for the value of a path parameter. A route without a
  rule is refused. `AnkoleWeb.JSONAPI.PolicyTest` asserts that each route has
  a rule and that each rule has a route.

  The policy also gives the tenant of `Ankole.Repo` to the Ash action of a
  Console route, and the Console Principal as the actor of the action. Ash
  policies stay disabled, so the actor only tells the action who operates.
  `Ankole.Repo` stays the owner of the tenant: the action gets the same value
  that `AnkoleWeb.Plugs.PutDataContext` selected. A site route gets no tenant.

  `AshJsonApi.Router` calls the controller of a route also after a halted
  `before_dispatch`. Thus a refusal throws the refused connection, and the
  `call/2` of `AnkoleWeb.JSONAPI.Router` returns it.
  """

  import Plug.Conn

  alias AnkoleWeb.ConsolePolicy

  @type scope :: :site | :console
  @type rule_key :: {module(), atom(), atom()}
  @type rule ::
          {authz_resource :: String.t(), authz_action :: String.t()}
          | {authz_resource :: String.t(), authz_action :: String.t(), {module(), atom()}}

  @principal_keys ~w(uid principal_uid agent_uid target_agent_uid)
  @placeholder_pattern ~r/\{(\w+)\}/

  # {resource, route type, action or relationship} => {AuthZ resource, AuthZ action}
  @rules %{
    site: %{
      # registry settings and operator Worker environment.
      {Ankole.AppConfigure.SiteOperations, :route, :console_list} =>
        {"app_configurations", "read"},
      {Ankole.AppConfigure.SiteOperations, :route, :console_show} =>
        {"app_configuration:{key}", "read"},
      {Ankole.AppConfigure.SiteOperations, :route, :console_update} =>
        {"app_configuration:{key}", "update"},
      {Ankole.AppConfigure.SiteOperations, :route, :console_delete} =>
        {"app_configuration:{key}", "reset"},
      {Ankole.AppConfigure.SiteOperations, :route, :console_decrypt} =>
        {"app_configuration:{key}", "decrypt"},
      {Ankole.AgentWorkers.WorkerEnv.SiteOperations, :route, :console_list} =>
        {"worker_envs", "read"},
      {Ankole.AgentWorkers.WorkerEnv.SiteOperations, :route, :console_put} =>
        {"worker_env:{name}", "update"},
      {Ankole.AgentWorkers.WorkerEnv.SiteOperations, :route, :console_delete} =>
        {"worker_env:{name}", "reset"},
      {Ankole.AgentWorkers.WorkerEnv.SiteOperations, :route, :console_decrypt} =>
        {"worker_env:{name}", "decrypt"},
      {Ankole.AgentWorkers.Providers.ConsoleOperations, :route, :console_kinds} =>
        {"worker_providers", "read"},
      {Ankole.AgentWorkers.Providers.ConsoleOperations, :route, :console_check} =>
        {"worker_provider:{provider_id}", "read"},
      {Ankole.ControlPlanePlugins.Console, :route, :list} => {"control_plane_plugins", "read"},
      {Ankole.ControlPlanePlugins.Console, :route, :configure} =>
        {"control_plane_plugins", "update"},
      # provider credentials and model catalog
      {Ankole.AIGateway.ProviderConfigs.Console, :route, :models} =>
        {"ai_gateway_providers", "read"},
      {Ankole.AIGateway.ProviderConfigs.Console, :route, :provider_kinds} =>
        {"ai_gateway_provider_kinds", "read"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :post, :console_add_credential} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :patch, :console_put_credential} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :delete, :console_delete_credential} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :patch, :console_credential_strategy} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Console, :route, :start} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Console, :route, :poll} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Console, :route, :complete} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Console, :route, :enterprise} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      # site tenants
      {Ankole.Tenants.Tenant, :index, :list} => {"site:tenants", "read"},
      {Ankole.Tenants.Tenant, :route, :brain_packs} => {"site:tenants", "read"},
      {Ankole.Tenants.Tenant, :post, :create} => {"site:tenants", "update"},
      {Ankole.Tenants.Tenant, :patch, :change_profile} => {"site:tenant:{id}", "update"},
      {Ankole.Tenants.Tenant, :delete, :begin_delete} => {"site:tenant:{id}", "delete"},
      {Ankole.Tenants.Tenant, :post, :suspend} => {"site:tenant:{id}", "update"},
      {Ankole.Tenants.Tenant, :delete, :resume} => {"site:tenant:{id}", "update"},
      {Ankole.Tenants.Tenant, :get, :privileged} => {"site:privileged_tenant", "read"},
      {Ankole.Tenants.Tenant, :patch, :transfer_site_administration} =>
        {"site:privileged_tenant", "update"},
      # site worker providers
      {Ankole.AgentWorkers.Providers.Provider, :index, :list} => {"worker_providers", "read"},
      {Ankole.AgentWorkers.Providers.Provider, :post, :add} => {"worker_providers", "update"},
      {Ankole.AgentWorkers.Providers.Provider, :patch, :configure_provider} =>
        {"worker_provider:{provider_id}", "update"},
      {Ankole.AgentWorkers.Providers.Provider, :delete, :delete_provider} =>
        {"worker_provider:{provider_id}", "delete"},
      # site AIGateway providers
      {Ankole.AIGateway.ProviderConfigs.Provider, :index, :list} =>
        {"ai_gateway_providers", "read"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :get, :read} =>
        {"ai_gateway_provider:{provider_id}", "read"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :patch, :put} =>
        {"ai_gateway_provider:{provider_id}", "update"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :delete, :retire} =>
        {"ai_gateway_provider:{provider_id}", "delete"},
      {Ankole.AIGateway.ProviderConfigs.Provider, :post, :enable_provider} =>
        {"ai_gateway_provider:{provider_id}", "update"}
    },
    console: %{
      # runtime views, Signal configuration, and Agent drive operations.
      {Ankole.Signals.ConsoleOperations, :route, :console_adapters} =>
        {"signals_adapters", "read"},
      {Ankole.Signals.ConsoleOperations, :route, :console_list_bindings} =>
        {"signal_bindings", "read"},
      {Ankole.Signals.ConsoleOperations, :route, :console_get_binding} =>
        {"agent:{agent_uid}:signal_bindings", "update"},
      {Ankole.Signals.ConsoleOperations, :route, :console_put_binding} =>
        {"agent:{agent_uid}:signal_bindings", "update"},
      {Ankole.Signals.ConsoleOperations, :route, :console_update_binding} =>
        {"agent:{agent_uid}:signal_bindings", "update",
         {Ankole.Signals.ConsoleActions, :update_binding_permissions}},
      {Ankole.Signals.ConsoleOperations, :route, :console_requeue} =>
        {"agent:{agent_uid}:signal_bindings", "update"},
      {Ankole.Sessions.ConsoleOperations, :route, :console_sessions} =>
        {"agent:{agent_uid}:sessions", "read"},
      {Ankole.Sessions.ConsoleOperations, :route, :console_standing_orders} =>
        {"conversations", "read"},
      {Ankole.Sessions.ConsoleOperations, :route, :console_put_standing_orders} =>
        {"conversations", "update"},
      {Ankole.BackgroundAgentJobs.ConsoleOperations, :route, :console_health} =>
        {"background_agent_jobs", "read"},
      {Ankole.BackgroundAgentJobs.ConsoleOperations, :route, :console_turns} =>
        {"background_agent_jobs", "read"},
      {Ankole.BackgroundActivities.ConsoleOperations, :route, :console_jobs} =>
        {"background_agent_jobs", "read"},
      {Ankole.BackgroundActivities.ConsoleOperations, :route, :console_workflow} =>
        {"agent:{agent_uid}:workflow", "read"},
      {Ankole.BackgroundActivities.ConsoleOperations, :route, :console_automation_runs} =>
        {"agent:{agent_uid}:automation_jobs", "read"},
      {Ankole.Files.ConsoleOperations, :route, :console_list} =>
        {"agent:{agent_uid}:files", "read"},
      {Ankole.Files.ConsoleOperations, :route, :console_move} =>
        {"agent:{agent_uid}:files", "update"},
      {Ankole.Files.ConsoleOperations, :route, :console_delete} =>
        {"agent:{agent_uid}:files", "delete"},
      {Ankole.ConsoleReadiness.ConsoleOperations, :route, :console_snapshot} =>
        {"console_readiness", "read"},

      # identity configuration, directory evidence, and reviewed access.
      {Ankole.IdentityProviders.Console, :route, :adapters} =>
        {"identity_provider_adapters", "read"},
      {Ankole.IdentityProviders.Console, :route, :providers} => {"identity_providers", "read"},
      {Ankole.IdentityProviders.Console, :route, :save_provider} =>
        {"identity_provider:{provider_id}", "update"},
      {Ankole.IdentityProviders.Console, :route, :run_sync} =>
        {"identity_provider:{provider_id}", "sync"},
      {Ankole.IdentityProviders.Console, :route, :directory} =>
        {"identity_provider:{provider_id}", "read"},
      {Ankole.IdentityProviders.Console, :route, :approve_directory} =>
        {"identity_provider:{provider_id}", "update"},
      {Ankole.IdentityProviders.Console, :route, :review_event} =>
        {"identity_provider:{provider_id}", "update"},
      {Ankole.Principals.Access, :route, :show} => {"principal:{uid}", "read"},
      {Ankole.Principals.Access, :route, :disable} => {"principal:{uid}", "update"},
      {Ankole.Principals.Access, :route, :restore} => {"principal:{uid}", "update"},
      {Ankole.Principals.Access, :route, :clear_restriction} => {"principal:{uid}", "update"},
      {Ankole.Principals.Access, :route, :retry_cleanup} => {"principal:{uid}", "update"},
      {Ankole.Principals.Access, :route, :reset_local_password} => {"principal:{uid}", "reset"},
      {Ankole.Principals.Access, :route, :unresolved_work} => {"principals", "update"},
      {Ankole.Principals.Access, :route, :classify_work} => {"principals", "update"},
      {Ankole.OIDC.Client, :route, :login_sources} => {"oidc_clients", "read"},
      {Ankole.OIDC.Client, :route, :console_rotate_secret} => {"oidc_client:{id}", "update"},
      # registry settings and operator Worker environment.
      {Ankole.AppConfigure.ConsoleOperations, :route, :console_list} =>
        {"app_configurations", "read"},
      {Ankole.AppConfigure.ConsoleOperations, :route, :console_show} =>
        {"app_configuration:{key}", "read"},
      {Ankole.AppConfigure.ConsoleOperations, :route, :console_update} =>
        {"app_configuration:{key}", "update"},
      {Ankole.AppConfigure.ConsoleOperations, :route, :console_delete} =>
        {"app_configuration:{key}", "reset"},
      {Ankole.AppConfigure.ConsoleOperations, :route, :console_decrypt} =>
        {"app_configuration:{key}", "decrypt"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_list} =>
        {"worker_envs", "read"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_put} =>
        {"worker_env:{name}", "update"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_delete} =>
        {"worker_env:{name}", "reset"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_decrypt} =>
        {"worker_env:{name}", "decrypt"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_list_for_agent} =>
        {"agent:{agent_uid}:worker_envs", "read"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_put_for_agent} =>
        {"agent:{agent_uid}:worker_env:{name}", "update"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_delete_for_agent} =>
        {"agent:{agent_uid}:worker_env:{name}", "reset"},
      {Ankole.AgentWorkers.WorkerEnv.ConsoleOperations, :route, :console_decrypt_for_agent} =>
        {"agent:{agent_uid}:worker_env:{name}", "decrypt"},
      {Ankole.Brain.ConsoleViews, :route, :health} => {"brain", "read"},
      {Ankole.Brain.ConsoleViews, :route, :dream} => {"brain", "update"},
      {Ankole.Brain.ConsoleViews, :route, :object_types} => {"brain", "read"},
      {Ankole.Brain.ConsoleViews, :route, :show_object} => {"brain", "read"},
      {Ankole.Brain.ConsoleViews, :route, :search_preview} => {"brain", "read"},
      {Ankole.Brain.ConsoleViews, :route, :principal_knowledge} => {"brain", "read"},
      {Ankole.AIAgent.Library.Console, :route, :global_capabilities} => {"agent_library", "read"},
      {Ankole.AIAgent.Library.Console, :route, :set_global_plugin} => {"agent_library", "update"},
      {Ankole.AIAgent.Library.Console, :route, :set_global_skill} => {"agent_library", "update"},
      {Ankole.AIAgent.Library.Console, :route, :agent_capabilities} =>
        {"agent:{agent_uid}:library", "read"},
      {Ankole.AIAgent.Library.Console, :route, :set_agent_plugin} =>
        {"agent:{agent_uid}:library", "update"},
      {Ankole.AIAgent.Library.Console, :route, :set_agent_skill} =>
        {"agent:{agent_uid}:library", "update"},
      {Ankole.AIAgent.Library.Console, :route, :documents} =>
        {"agent:{agent_uid}:library", "read"},
      {Ankole.AIAgent.Library.Console, :route, :replace_document} =>
        {"agent:{agent_uid}:library", "update"},
      # Agent model configuration and token quotas
      {Ankole.AIAgent.Console, :route, :model_profiles} =>
        {"agent:{agent_uid}:model_profiles", "read"},
      {Ankole.AIAgent.Console, :route, :put_model_profile} =>
        {"agent:{agent_uid}:model_profile:{profile}", "update"},
      {Ankole.AIAgent.Console, :route, :delete_model_profile} =>
        {"agent:{agent_uid}:model_profile:{profile}", "delete"},
      {Ankole.AIAgent.Console, :route, :put_provider_hosted} =>
        {"agent:{agent_uid}:model_profiles", "update"},
      {Ankole.AIAgent.Console, :route, :token_quota} => {"agent:{agent_uid}:token_quota", "read"},
      {Ankole.AIAgent.Console, :route, :put_token_quota} =>
        {"agent:{agent_uid}:token_quota", "update"},
      {Ankole.AIAgent.Console, :route, :delete_token_quota} =>
        {"agent:{agent_uid}:token_quota", "delete"},
      {Ankole.AIAgent.Console, :route, :reset_token_quota} =>
        {"agent:{agent_uid}:token_quota", "update"},
      # background agent jobs
      {Ankole.BackgroundAgentJobs.Schemas.Job, :index, :console_list} =>
        {"background_agent_jobs", "read"},
      {Ankole.BackgroundAgentJobs.Schemas.Job, :get, :read} => {"background_agent_jobs", "read"},
      {Ankole.BackgroundAgentJobs.Schemas.Job, :route, :console_cancel} =>
        {"background_agent_jobs", "delete"},
      {Ankole.BackgroundAgentJobs.Schemas.Job, :route, :console_complete} =>
        {"background_agent_jobs", "update"},
      # agent skill lessons
      {Ankole.AIAgent.Library.Schemas.AgentSkillLesson, :index, :console_list} =>
        {"agent:{agent_uid}:library", "read"},
      {Ankole.AIAgent.Library.Schemas.AgentSkillLesson, :route, :console_teach} =>
        {"agent:{agent_uid}:library", "update"},
      {Ankole.AIAgent.Library.Schemas.AgentSkillLesson, :route, :revoke} =>
        {"agent:{agent_uid}:library", "update"},
      # agents
      {Ankole.Principals.Agent, :index, :console_list} => {"agents", "read"},
      {Ankole.Principals.Agent, :get, :read} => {"agent:{uid}", "read"},
      {Ankole.Principals.Agent, :route, :console_create} => {"agents", "update"},
      {Ankole.Principals.Agent, :route, :console_update} => {"agent:{uid}", "update"},
      {Ankole.Principals.Agent, :route, :console_delete} => {"agent:{uid}", "delete"},
      {Ankole.Principals.Agent, :route, :console_enable} => {"agent:{uid}", "update"},
      # agent workers
      {Ankole.AgentWorkers.AgentWorker, :index, :console_list} => {"agent_workers", "read"},
      {Ankole.AgentWorkers.AgentWorker, :route, :console_assign_provider} =>
        {"agent:{agent_uid}", "update"},
      # ai-gateway conversations
      {Ankole.AIGateway.Schemas.Conversation, :index, :console_list} =>
        {"ai_gateway_conversations", "read"},
      {Ankole.AIGateway.Schemas.Conversation, :get, :read} =>
        {"ai_gateway_conversations", "read"},
      {Ankole.AIGateway.Schemas.Message, :index, :console_list} =>
        {"ai_gateway_conversations", "read"},
      # automation jobs
      {Ankole.AutomationJobs.Schemas.Job, :index, :console_list} => {"automation_jobs", "read"},
      {Ankole.AutomationJobs.Schemas.Job, :get, :read} =>
        {"agent:{agent_uid}:automation_jobs", "read"},
      {Ankole.AutomationJobs.Schemas.Run, :index, :console_list} =>
        {"agent:{agent_uid}:automation_jobs", "read"},
      # OIDC clients
      {Ankole.OIDC.Client, :index, :console_list} => {"oidc_clients", "read"},
      {Ankole.OIDC.Client, :route, :console_create} => {"oidc_clients", "update"},
      {Ankole.OIDC.Client, :get, :read} => {"oidc_client:{id}", "read"},
      {Ankole.OIDC.Client, :patch, :console_update} => {"oidc_client:{id}", "update"},
      {Ankole.OIDC.Client, :delete, :console_delete} => {"oidc_client:{id}", "delete"},
      {Ankole.OIDC.LogoutDelivery, :index, :console_list} => {"oidc_client:{client_id}", "read"},
      {Ankole.OIDC.LogoutDelivery, :route, :console_retry} =>
        {"oidc_client:{client_id}", "update"},
      # webhook endpoints
      {Ankole.Signals.WebhookEndpoint, :index, :console_list} => {"webhooks", "read"},
      {Ankole.Signals.WebhookEndpoint, :route, :create_operator_endpoint} =>
        {"webhooks", "update"},
      {Ankole.Signals.WebhookEndpoint, :route, :cancel_operator_endpoint} =>
        {"webhooks", "delete"},
      # cron schedules and checkbacks
      {Ankole.Schedule.Schemas.CronSchedule, :index, :console_list} => {"schedules", "read"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_create} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :get, :read} =>
        {"agent:{agent_uid}:schedules", "read"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_update} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_pause} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_resume} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_remove} =>
        {"agent:{agent_uid}:schedules", "delete"},
      {Ankole.Schedule.Schemas.CronSchedule, :route, :console_run} =>
        {"agent:{agent_uid}:schedules", "update"},
      {Ankole.Schedule.Schemas.ScheduledEvent, :index, :console_cron_runs} =>
        {"agent:{agent_uid}:schedules", "read"},
      {Ankole.Schedule.Schemas.ScheduledEvent, :index, :console_checkbacks} =>
        {"schedules", "read"},
      {Ankole.Schedule.Schemas.ScheduledEvent, :route, :console_cancel_checkback} =>
        {"agent:{agent_uid}:schedules", "delete"},
      # signal bindings
      {Ankole.Signals.Binding, :route, :console_disable} =>
        {"agent:{agent_uid}:signal_bindings", "delete"},
      # brain
      {Ankole.Brain.Schemas.Object, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Object, :route, :console_create} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :console_update} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :fork_library_page} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :console_rollback} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :console_forget} => {"brain", "update"},
      {Ankole.Brain.Schemas.Object, :route, :restore_object} => {"brain", "update"},
      {Ankole.Brain.Schemas.ObjectVersion, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Claim, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Claim, :route, :console_supersede} => {"brain", "update"},
      {Ankole.Brain.Schemas.Claim, :route, :console_forget} => {"brain", "update"},
      {Ankole.Brain.Schemas.Claim, :route, :console_resolve} => {"brain", "update"},
      {Ankole.Brain.Schemas.Contradiction, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Contradiction, :route, :decide} => {"brain", "update"},
      {Ankole.Brain.Schemas.SchemaSuggestion, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.SchemaSuggestion, :route, :console_approve} => {"brain", "update"},
      {Ankole.Brain.Schemas.SchemaSuggestion, :route, :console_reject} => {"brain", "update"},
      {Ankole.Brain.Schemas.MergeSuggestion, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.MergeSuggestion, :route, :console_approve} => {"brain", "update"},
      {Ankole.Brain.Schemas.MergeSuggestion, :route, :console_reject} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :index, :console_list} => {"brain", "read"},
      {Ankole.Brain.Schemas.Source, :route, :console_register} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :route, :update_default_scope} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :route, :console_learn} => {"brain", "update"},
      {Ankole.Brain.Schemas.Source, :route, :archive_source} => {"brain", "update"},
      # Identity and permission administration.
      {Ankole.Principals.Principal, :index, :console_list} => {"principals", "read"},
      {Ankole.Principals.Principal, :get, :read} => {"principal:{uid}", "read"},
      {Ankole.Principals.Principal, :post, :create_local_user} => {"principals", "update"},
      {Ankole.Principals.Principal, :patch, :update_human} => {"principal:{uid}", "update"},
      {Ankole.Principals.MappingRequest, :index, :console_list} =>
        {"identity_mapping_requests", "read"},
      {Ankole.Principals.MappingRequest, :delete, :delete_in_tx} =>
        {"identity_mapping_requests", "update"},
      {Ankole.Principals.MappingRequest, :route, :bind_request} =>
        {"identity_mapping_requests", "update"},
      {Ankole.Principals.MappingRequest, :route, :bind_subject} =>
        {"identity_mapping_requests", "update"},
      {Ankole.AuthZ.Group, :index, :console_list} => {"principal_groups", "read"},
      {Ankole.AuthZ.Group, :post, :create} => {"principal_groups", "update"},
      {Ankole.AuthZ.Group, :route, :preview_computed_members} => {"principal_groups", "read"},
      {Ankole.AuthZ.Group, :get, :read} => {"principal_group:{name}", "read"},
      {Ankole.AuthZ.Group, :patch, :update} => {"principal_group:{name}", "update"},
      {Ankole.AuthZ.Group, :delete, :delete_operator_group} =>
        {"principal_group:{name}", "delete"},
      {Ankole.AuthZ.Group, :route, :list_members} => {"principal_group:{name}:members", "read"},
      {Ankole.AuthZ.Group, :route, :add_member} => {"principal_group:{name}:members", "update"},
      {Ankole.AuthZ.Group, :route, :remove_member} =>
        {"principal_group:{name}:members", "update"},
      {Ankole.AuthZ.Group, :index, :of_principal} => {"principal:{uid}:groups", "read"},
      {Ankole.AuthZ.Grant, :index, :of_principal} => {"principal:{uid}:grants", "read"},
      {Ankole.AuthZ.Grant, :index, :of_group} => {"principal_group:{name}:grants", "read"},
      {Ankole.AuthZ.Grant, :post, :create_operator_grant} => {"permission_grants", "update"},
      {Ankole.AuthZ.Grant, :get, :by_id} => {"permission_grant:{id}", "read"},
      {Ankole.AuthZ.Grant, :patch, :update_operator_grant} => {"permission_grant:{id}", "update"},
      {Ankole.AuthZ.Grant, :delete, :delete_operator_grant} => {"permission_grant:{id}", "delete"}
    }
  }

  @doc "Gives the rules of the routers of one scope."
  @spec rules(scope()) :: %{rule_key() => rule()}
  def rules(scope), do: Map.fetch!(@rules, scope)

  @doc """
  Gives the rule key of a route: the resource, the route type, and the
  relationship of a relationship route or else the action.
  """
  @spec rule_key(module(), AshJsonApi.Resource.Route.t()) :: rule_key()
  def rule_key(resource, route), do: {resource, route.type, route.relationship || route.action}

  @doc """
  The `before_dispatch` function of a JSON:API router.

  The OpenAPI document and the response for an unknown path need no rule.
  AshJsonApi sends the OpenAPI document without a content type, so this
  function sets it. A test router can give its own rules.
  """
  def before_dispatch(conn, route_info, scope, rules \\ nil)

  def before_dispatch(conn, :open_api, _scope, _rules),
    do: put_resp_content_type(conn, "application/json")

  def before_dispatch(conn, :not_found, _scope, _rules), do: conn

  def before_dispatch(
        conn,
        %{resource: resource, route: route, params: params},
        scope,
        rules
      ) do
    with {:ok, rule} <- Map.fetch(rules || rules(scope), rule_key(resource, route)),
         {conn, params} <- resolve_targets(conn, resource, params, rule),
         :ok <- authorize_rule(conn, params, rule) do
      conn
      |> Ash.PlugHelpers.set_tenant(tenant(scope))
      |> Ash.PlugHelpers.set_actor(conn.assigns[:current_principal])
    else
      _refused -> refuse(conn)
    end
  end

  def before_dispatch(conn, _route_info, _scope, _rules), do: refuse(conn)

  @doc """
  Resolves one path target parameter to the canonical form that both
  Principal/AuthZ and the Ash resource or domain action consume.

  Every `{param}` placeholder in `@rules` must match an explicit clause here.
  """
  @spec resolve_target!(module(), String.t(), String.t()) :: String.t()
  def resolve_target!(_resource, param, value)
      when param in @principal_keys and is_binary(value) do
    Ankole.PrincipalKey.canonicalize(value)
  end

  def resolve_target!(_resource, param, value)
      when param in ["id", "client_id"] and is_binary(value) do
    canonical_uuid(value)
  end

  def resolve_target!(resource, "name", value)
      when resource in [Ankole.AuthZ.Group, Ankole.AuthZ.Grant] and is_binary(value) do
    Ankole.AuthZ.resolve_group_name(value)
  end

  def resolve_target!(resource, "name", value)
      when resource in [
             Ankole.AgentWorkers.WorkerEnv.SiteOperations,
             Ankole.AgentWorkers.WorkerEnv.ConsoleOperations
           ] and is_binary(value) do
    value
  end

  def resolve_target!(resource, "provider_id", value)
      when resource in [
             Ankole.AIGateway.ProviderConfigs.Provider,
             Ankole.AIGateway.ProviderConfigs.Console
           ] and is_binary(value) do
    Ankole.AIGateway.ProviderConfigs.Provider.normalize_id(value)
  end

  def resolve_target!(Ankole.IdentityProviders.Console, "provider_id", value)
      when is_binary(value) do
    Ankole.IdentityProviders.Config.canonicalize_id(value)
  end

  def resolve_target!(resource, "provider_id", value)
      when resource in [
             Ankole.AgentWorkers.Providers.Provider,
             Ankole.AgentWorkers.Providers.ConsoleOperations
           ] and is_binary(value) do
    value
  end

  def resolve_target!(Ankole.AIAgent.Console, "profile", value) when is_binary(value) do
    Ankole.AIAgent.ModelProfiles.canonicalize_profile(value)
  end

  def resolve_target!(resource, "key", value)
      when resource in [
             Ankole.AppConfigure.SiteOperations,
             Ankole.AppConfigure.ConsoleOperations
           ] and is_binary(value) do
    value
  end

  def resolve_target!(resource, param, _value) do
    raise ArgumentError,
          "no target resolver declared for #{inspect(resource)} parameter #{inspect(param)}"
  end

  @doc "Gives the refused connection of a `before_dispatch` call, or the result of `call`."
  @spec dispatch(Plug.Conn.t(), (Plug.Conn.t() -> Plug.Conn.t())) :: Plug.Conn.t()
  def dispatch(conn, call) do
    call.(conn)
  catch
    {__MODULE__, %Plug.Conn{} = refused} -> refused
  end

  defp resolve_targets(conn, resource, params, rule) do
    params =
      params
      |> canonical_principals()
      |> resolve_rule_targets(resource, elem(rule, 0))

    conn = %{
      conn
      | path_params: Map.merge(conn.path_params, params),
        query_params: canonical_principals(conn.query_params),
        body_params: canonical_body(conn.body_params)
    }

    {conn, params}
  end

  defp resolve_rule_targets(params, resource, authz_resource) do
    @placeholder_pattern
    |> Regex.scan(authz_resource)
    |> Enum.reduce(params, fn [_match, name], acc ->
      Map.update!(acc, name, &resolve_target!(resource, name, &1))
    end)
  end

  defp canonical_body(%{"data" => %{} = data} = body) do
    data =
      data
      |> canonical_principals()
      |> canonical_nested_attributes()

    Map.put(body, "data", data)
  end

  defp canonical_body(body), do: body

  defp canonical_nested_attributes(%{"attributes" => %{} = attributes} = data),
    do: Map.put(data, "attributes", canonical_principals(attributes))

  defp canonical_nested_attributes(data), do: data

  defp canonical_principals(params) do
    Enum.reduce(@principal_keys, params, fn key, acc ->
      case Map.fetch(acc, key) do
        {:ok, uid} when is_binary(uid) -> Map.put(acc, key, Ankole.PrincipalKey.canonicalize(uid))
        _ -> acc
      end
    end)
  end

  defp canonical_uuid(value) do
    trimmed = String.trim(value)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} -> uuid
      :error -> trimmed
    end
  end

  defp authorize_rule(conn, params, rule) do
    Enum.reduce_while(permissions(conn, params, rule), :ok, fn {resource, action}, :ok ->
      case ConsolePolicy.authorize(conn, resource, action) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp permissions(_conn, params, {authz_resource, action}),
    do: [{expand(authz_resource, params), action}]

  defp permissions(conn, params, {authz_resource, action, {module, function}}) do
    args = Map.merge(body_arguments(conn), conn.query_params)
    apply(module, function, [params, args, expand(authz_resource, params), action])
  end

  defp body_arguments(%Plug.Conn{body_params: %{"data" => %{} = data}}), do: data
  defp body_arguments(_conn), do: %{}

  defp tenant(:site), do: nil
  defp tenant(:console), do: Ankole.Repo.tenant_id()

  defp expand(authz_resource, params) do
    Regex.replace(@placeholder_pattern, authz_resource, fn _match, name ->
      Map.fetch!(params, name)
    end)
  end

  defp refuse(conn) do
    body =
      AshJsonApi.Serializer.serialize_errors(nil, %AshJsonApi.Error{
        status_code: 403,
        code: "forbidden",
        title: "Forbidden",
        detail: "access denied"
      })

    refused =
      conn
      |> put_resp_content_type("application/vnd.api+json")
      |> send_resp(403, body)
      |> halt()

    throw({__MODULE__, refused})
  end
end
