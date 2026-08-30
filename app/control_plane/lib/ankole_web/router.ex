defmodule AnkoleWeb.Router do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Plug.PutApiSpec, as: PutAPISpec

  @moduledoc """
  Routes the Phoenix shell, setup API, and admin auth API.

  Phoenix owns browser/session protection here. Application screens are still
  rendered by the SPAs mounted by `AnkoleWeb.SpaController`.
  """

  use AnkoleWeb, :router

  # Four request surfaces, each with its own protection profile:
  #
  #   :browser     — the HTML shells that boot the React SPAs. Full browser
  #                  hardening (session, flash, CSRF, secure headers).
  #   :session_api — setup/auth JSON that mutates server state. Deliberately
  #                  keeps the browser session + CSRF rather than going
  #                  stateless, because only the same-origin SPAs call it.
  #   :openapi     — serves the spec document itself.
  #   :console_api — the stateless bearer-token REST API for the console.
  #   :ai_gateway_api — agent/admin-scoped runtime AI API.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :openapi do
    plug :accepts, ["json"]
    plug PutAPISpec, module: AnkoleWeb.APISpec
  end

  pipeline :session_api do
    # JSON endpoints that mutate setup or auth state still use the browser
    # session and CSRF protection. They are API-shaped, not public stateless APIs:
    # the setup wizard and sign-in SPA call them from the same origin, so the
    # sealed session cookie carries the auth state and CSRF blocks cross-site POSTs.
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :console_api do
    # No session/CSRF here. Each request must present its own bearer token, which
    # RequireConsoleAccessToken verifies and resolves to an active human admin.
    plug :accepts, ["json"]
    plug PutAPISpec, module: AnkoleWeb.APISpec
    plug AnkoleWeb.Plugs.RequireConsoleAccessToken
  end

  pipeline :ai_gateway_api do
    # Runtime AI calls are stateless HTTP requests authenticated as either an
    # agent-scoped AIGateway token or an active human admin console token.
    plug :accepts, ["json", "event-stream"]
    plug PutAPISpec, module: AnkoleWeb.APISpec
    plug AnkoleWeb.Plugs.RequireAIGatewayAccessToken
  end

  # `/.internal-apis` is the private contract between the SPAs and the server —
  # the setup wizard and sign-in app drive these; they are not a public API.
  scope "/.internal-apis", AnkoleWeb do
    pipe_through :session_api

    get "/setup/state", SetupController, :state
    post "/setup/sessions", SetupController, :create_session
    delete "/setup/sessions/current", SetupController, :delete_session

    post "/setup/bootstrap-activation-code/log-entries",
         SetupController,
         :create_activation_code_log_entry

    get "/setup/plugins", SetupController, :plugins
    put "/setup/plugins/enabled", SetupController, :update_plugins
    get "/setup/brain-packs", SetupController, :brain_packs
    put "/setup/brain-packs", SetupController, :put_brain_packs
    get "/setup/identity-provider-adapters", SetupController, :identity_provider_adapters
    put "/setup/identity-providers/:provider_id", SetupController, :put_identity_provider

    post "/setup/identity-providers/:provider_id/oidc/authorizations",
         SetupController,
         :oidc_authorization

    post "/setup/local-admin", SetupController, :create_local_admin

    get "/session", AuthController, :session
    delete "/session", AuthController, :delete_session
    post "/oauth/token", AuthController, :oauth_token
    get "/identity-providers", AuthController, :identity_providers
    post "/sessions/local-password", AuthController, :local_password_login
    post "/sessions/local-password/change", AuthController, :local_password_change
  end

  # The spec document is public (no bearer token) so tooling can read it without
  # credentials; the API endpoints it describes still require one below.
  scope "/api/v1" do
    pipe_through :openapi

    get "/openapi.json", OpenAPISpex.Plug.RenderSpec, []
  end

  scope "/api/v1", AnkoleWeb do
    pipe_through :console_api

    get "/app-configurations", AppConfigurationController, :index
    get "/app-configurations/:key", AppConfigurationController, :show
    put "/app-configurations/:key", AppConfigurationController, :update
    delete "/app-configurations/:key", AppConfigurationController, :delete
    post "/app-configurations/:key/decryptions", AppConfigurationController, :decrypt

    get "/worker-envs", WorkerEnvController, :index
    get "/worker-envs/:name", WorkerEnvController, :show
    put "/worker-envs/:name", WorkerEnvController, :update
    delete "/worker-envs/:name", WorkerEnvController, :delete
    post "/worker-envs/:name/decryptions", WorkerEnvController, :decrypt

    get "/agents/:agent_uid/worker-envs", WorkerEnvController, :index_for_agent
    put "/agents/:agent_uid/worker-envs/:name", WorkerEnvController, :update_for_agent
    delete "/agents/:agent_uid/worker-envs/:name", WorkerEnvController, :delete_for_agent

    post "/agents/:agent_uid/worker-envs/:name/decryptions",
         WorkerEnvController,
         :decrypt_for_agent

    get "/principals", PrincipalController, :index
    post "/principals", PrincipalController, :create
    get "/principals/:uid", PrincipalController, :show
    patch "/principals/:uid", PrincipalController, :update
    get "/principals/:uid/groups", PrincipalController, :groups
    get "/principals/:uid/grants", PrincipalController, :grants

    post "/principals/:uid/local-password-resets",
         PrincipalController,
         :create_local_password_reset

    get "/principal-groups", AuthZGroupController, :index
    post "/principal-groups", AuthZGroupController, :create

    post "/principal-groups/computed-member-previews",
         AuthZGroupController,
         :preview_computed_members

    get "/principal-groups/:name", AuthZGroupController, :show
    patch "/principal-groups/:name", AuthZGroupController, :update
    delete "/principal-groups/:name", AuthZGroupController, :delete
    get "/principal-groups/:name/members", AuthZGroupController, :members
    put "/principal-groups/:name/members/:principal_uid", AuthZGroupController, :add_member
    delete "/principal-groups/:name/members/:principal_uid", AuthZGroupController, :remove_member
    get "/principal-groups/:name/grants", AuthZGroupController, :grants

    post "/permission-grants", PermissionGrantController, :create
    get "/permission-grants/:id", PermissionGrantController, :show
    patch "/permission-grants/:id", PermissionGrantController, :update
    delete "/permission-grants/:id", PermissionGrantController, :delete

    get "/brain/health", BrainController, :health
    get "/brain/objects", BrainController, :list_objects
    get "/brain/object-types", BrainController, :object_types
    post "/brain/objects", BrainController, :create_object
    put "/brain/objects", BrainController, :update_object
    post "/brain/search-preview", BrainController, :search_preview
    get "/brain/claims", BrainController, :list_claims
    post "/brain/claims/:claim_id/supersede", BrainController, :supersede_claim
    post "/brain/claims/:claim_id/forget", BrainController, :forget_claim
    post "/brain/claims/:claim_id/resolve", BrainController, :resolve_take
    get "/brain/contradictions", BrainController, :list_contradictions
    post "/brain/contradictions/:contradiction_id/decide", BrainController, :decide_contradiction
    get "/brain/suggestions", BrainController, :list_suggestions
    post "/brain/suggestions/:suggestion_id/decide", BrainController, :decide_suggestion
    get "/brain/merge-suggestions", BrainController, :list_merge_suggestions

    post "/brain/merge-suggestions/:suggestion_id/decide",
         BrainController,
         :decide_merge_suggestion

    get "/brain/sources", BrainController, :list_sources
    post "/brain/sources", BrainController, :create_source
    post "/brain/sources/:source_id/learn", BrainController, :learn_source
    post "/brain/sources/:source_id/archive", BrainController, :archive_source
    get "/brain/principals/:principal_uid/knowledge", BrainController, :principal_knowledge
    # Object slugs contain `/`, so these operations carry the slug as a query
    # parameter or in the body instead of a wildcard path segment, which the
    # OpenAPI document could not express.
    get "/brain/objects/show", BrainController, :show_object
    get "/brain/objects/versions", BrainController, :object_versions
    post "/brain/objects/rollback", BrainController, :rollback_object
    post "/brain/objects/forget", BrainController, :forget_object
    post "/brain/objects/restore", BrainController, :restore_object
    post "/brain/objects/fork", BrainController, :fork_object

    get "/agents", AgentController, :index
    post "/agents", AgentController, :create
    get "/agents/:agent_uid", AgentController, :show
    patch "/agents/:agent_uid", AgentController, :update
    delete "/agents/:agent_uid", AgentController, :delete
    post "/agents/:agent_uid/enable", AgentController, :enable

    get "/agent-library/capabilities", AgentLibraryCapabilityController, :global_index

    put "/agent-library/agent-plugins/:id",
        AgentLibraryCapabilityController,
        :put_global_agent_plugin

    put "/agent-library/skills/:id",
        AgentLibraryCapabilityController,
        :put_global_skill

    get "/agents/:agent_uid/library-capabilities",
        AgentLibraryCapabilityController,
        :agent_index

    put "/agents/:agent_uid/library-capabilities/agent-plugins/:id",
        AgentLibraryCapabilityController,
        :put_agent_plugin_override

    put "/agents/:agent_uid/library-capabilities/skills/:id",
        AgentLibraryCapabilityController,
        :put_agent_skill_override

    get "/control-plane-plugins", ControlPlanePluginController, :index
    put "/control-plane-plugins", ControlPlanePluginController, :update

    get "/agents/:agent_uid/library-documents", AgentLibraryController, :index

    put "/agents/:agent_uid/library-documents/:document_kind",
        AgentLibraryController,
        :update

    get "/agents/:agent_uid/skill-lessons",
        AgentSkillLessonController,
        :index

    post "/agents/:agent_uid/skill-lessons",
         AgentSkillLessonController,
         :create

    post "/agents/:agent_uid/skill-lessons/:lesson_id/retire",
         AgentSkillLessonController,
         :retire

    get "/console-readiness", ConsoleReadinessController, :show

    get "/agent-computer-workers", AgentComputerWorkerController, :index

    get "/background-agent-jobs", BackgroundAgentJobController, :index

    get "/background-agent-jobs/health", BackgroundAgentJobController, :health
    get "/background-agent-jobs/:job_id", BackgroundAgentJobController, :show
    post "/background-agent-jobs/:job_id/cancel", BackgroundAgentJobController, :cancel
    post "/background-agent-jobs/:job_id/complete", BackgroundAgentJobController, :complete

    get "/ai-gateway/conversations", AIGatewayConversationController, :index

    get "/ai-gateway/conversations/:conversation_id",
        AIGatewayConversationController,
        :show

    get "/ai-gateway/conversations/:conversation_id/messages",
        AIGatewayConversationController,
        :messages

    get "/agent-computer-workers/:worker_id/files", WorkerFileController, :index

    get "/agent-computer-workers/:worker_id/files/content",
        WorkerFileController,
        :download

    post "/agent-computer-workers/:worker_id/files", WorkerFileController, :upload
    post "/agent-computer-workers/:worker_id/file-moves", WorkerFileController, :move

    delete "/agent-computer-workers/:worker_id/files",
           WorkerFileController,
           :delete

    get "/ai-gateway/provider-kinds", AIGatewayProviderController, :provider_kinds
    get "/ai-gateway/providers", AIGatewayProviderController, :index
    get "/ai-gateway/providers/:provider_id", AIGatewayProviderController, :show
    put "/ai-gateway/providers/:provider_id", AIGatewayProviderController, :put_provider
    delete "/ai-gateway/providers/:provider_id", AIGatewayProviderController, :delete_provider

    post "/ai-gateway/providers/:provider_id/enable",
         AIGatewayProviderController,
         :enable_provider

    post "/ai-gateway/providers/:provider_id/credentials",
         AIGatewayProviderController,
         :add_credential

    put "/ai-gateway/providers/:provider_id/credentials/:credential_id",
        AIGatewayProviderController,
        :put_credential

    delete "/ai-gateway/providers/:provider_id/credentials/:credential_id",
           AIGatewayProviderController,
           :delete_credential

    put "/ai-gateway/providers/:provider_id/credential-pool/strategy",
        AIGatewayProviderController,
        :put_credential_strategy

    post "/ai-gateway/providers/:provider_id/chatgpt-login",
         AIGatewayProviderController,
         :start_chatgpt_login

    post "/ai-gateway/providers/:provider_id/chatgpt-login/poll",
         AIGatewayProviderController,
         :poll_chatgpt_login

    post "/ai-gateway/providers/:provider_id/chatgpt-login/browser-callback",
         AIGatewayProviderController,
         :complete_chatgpt_browser_login

    post "/ai-gateway/providers/:provider_id/chatgpt-enterprise-credentials",
         AIGatewayProviderController,
         :add_chatgpt_enterprise_credential

    get "/agents/:agent_uid/model-profiles", AgentController, :index_model_profiles

    get "/identity-provider-adapters", IdentityProviderController, :adapters
    get "/identity-providers", IdentityProviderController, :index
    put "/identity-providers/:provider_id", IdentityProviderController, :put_provider
    post "/identity-providers/:provider_id/sync-runs", IdentityProviderController, :run_sync

    get "/identity-mapping-requests", IdentityMappingRequestController, :index
    post "/identity-mapping-requests/:id/bind", IdentityMappingRequestController, :bind
    delete "/identity-mapping-requests/:id", IdentityMappingRequestController, :delete
    post "/identity-mappings", IdentityMappingRequestController, :create_mapping

    put "/agents/:agent_uid/provider-hosted", AgentController, :put_provider_hosted

    put "/agents/:agent_uid/model-profiles/:profile",
        AgentController,
        :put_model_profile

    delete "/agents/:agent_uid/model-profiles/:profile",
           AgentController,
           :delete_model_profile

    get "/signal-adapters", SignalBindingController, :adapters

    get "/signal-bindings", SignalBindingController, :index

    get "/agents/:agent_uid/signal-bindings/:binding_name",
        SignalBindingController,
        :show

    put "/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name",
        SignalBindingController,
        :put_binding

    patch "/agents/:agent_uid/signal-bindings/:binding_name",
          SignalBindingController,
          :update_binding

    delete "/agents/:agent_uid/signal-bindings/:binding_name",
           SignalBindingController,
           :delete

    post "/agents/:agent_uid/signal-deliveries/requeue",
         SignalBindingController,
         :requeue_delivery

    get "/signal-channels/:channel_id/standing-orders",
        SignalBindingController,
        :show_channel_standing_orders

    put "/signal-channels/:channel_id/standing-orders",
        SignalBindingController,
        :put_channel_standing_orders

    get "/agents/:agent_uid/sessions", AgentSessionController, :index

    get "/cron-schedules", ScheduleController, :index_cron
    post "/agents/:agent_uid/cron-schedules", ScheduleController, :create_cron
    get "/agents/:agent_uid/cron-schedules/:cron_schedule_id", ScheduleController, :show_cron
    patch "/agents/:agent_uid/cron-schedules/:cron_schedule_id", ScheduleController, :update_cron

    post "/agents/:agent_uid/cron-schedules/:cron_schedule_id/pause",
         ScheduleController,
         :pause_cron

    post "/agents/:agent_uid/cron-schedules/:cron_schedule_id/resume",
         ScheduleController,
         :resume_cron

    delete "/agents/:agent_uid/cron-schedules/:cron_schedule_id", ScheduleController, :remove_cron
    post "/agents/:agent_uid/cron-schedules/:cron_schedule_id/runs", ScheduleController, :run_cron
    get "/agents/:agent_uid/cron-schedules/:cron_schedule_id/runs", ScheduleController, :cron_runs
    get "/checkbacks", ScheduleController, :index_checkbacks

    delete "/agents/:agent_uid/checkbacks/:scheduled_event_id",
           ScheduleController,
           :cancel_checkback

    get "/webhook-endpoints", WebhookEndpointController, :index

    delete "/agents/:agent_uid/webhook-endpoints/:webhook_endpoint_id",
           WebhookEndpointController,
           :delete

    get "/automation-jobs", AutomationJobController, :index

    get "/agents/:agent_uid/automation-jobs/:automation_job_id",
        AutomationJobController,
        :show
  end

  scope "/api/v1/ai-gateway", AnkoleWeb do
    pipe_through :ai_gateway_api

    get "/models", AIGatewayController, :models
    get "/files", AIGatewayFilesController, :index
    post "/files", AIGatewayFilesController, :create
    get "/files/:file_id/content", AIGatewayFilesController, :content
    get "/files/:file_id", AIGatewayFilesController, :show
    delete "/files/:file_id", AIGatewayFilesController, :delete
    get "/responses", AIGatewayWebSocketController, :responses
    get "/responses/:response_id", AIGatewayController, :retrieve_response
    post "/responses", AIGatewayController, :responses
    post "/embeddings", AIGatewayController, :embeddings
    post "/rerank", AIGatewayController, :rerank
    post "/web_search", AIGatewayController, :web_search
    post "/web_fetch", AIGatewayController, :web_fetch
  end

  # Capability URL ingress for external task receipts. The token in the path is
  # the only admission credential, so this route has no session, CSRF, bearer
  # token, or provider-handler pipeline. The event-callbacks subtree keeps it
  # distinct from provider-handler ingress.
  scope "/webhooks/v1/event-callbacks", AnkoleWeb do
    post "/:token", WebhookCallbackController, :handle
  end

  # Provider webhook ingress. Not a RESTful API surface, so it lives outside
  # /api/v1 and outside every pipeline: no session, no CSRF, no bearer token,
  # and no Accept negotiation (providers send arbitrary Accept headers).
  # Authenticating the provider is the declared handler's job — Bot Framework
  # JWT, Graph clientState, or whatever the provider signs with.
  scope "/webhooks", AnkoleWeb do
    post "/v1/:handler_id/:instance_id/:kind", SignalWebhookController, :handle
  end

  # Browser-facing HTML. The `*path` catch-alls let each SPA own its own
  # client-side routing: any deep link under /console or /setup returns the same
  # shell, and the React router takes over. SpaController re-checks setup/auth
  # state on every shell request, so the access gate stays server-side rather
  # than trusting the SPA to redirect.
  scope "/", AnkoleWeb do
    pipe_through :browser

    get "/", SpaController, :home
    get "/sessions/new", SpaController, :sessions_new
    get "/sessions/oidc/:provider_id/authorization", AuthController, :oidc_authorization
    # The OIDC redirect lands here as a top-level browser navigation (not via the
    # SPA), so it carries the session cookie holding the pending OIDC state.
    get "/sessions/oidc/:provider_id/callback", AuthController, :oidc_callback
    get "/console", SpaController, :console
    get "/console/*path", SpaController, :console
    get "/setup", SpaController, :setup
    get "/setup/*path", SpaController, :setup
  end
end
