defmodule AnkoleWeb.Router do
  alias OpenApiSpex, as: OpenAPISpex
  alias OpenAPISpex.Plug.PutApiSpec, as: PutAPISpec

  @moduledoc """
  Routes the Phoenix shell, setup API, and admin auth API.

  Phoenix owns browser/session protection here. Application screens are still
  rendered by the SPAs mounted by `AnkoleWeb.SpaController`.
  """

  use AnkoleWeb, :router

  # Browser shells and Console JSON APIs use the sealed browser cookie and CSRF.
  # Runtime AI APIs accept Agent and OIDC Human bearer credentials.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :browser_csrf
    plug :put_secure_browser_headers
    plug :private_response
  end

  pipeline :openapi do
    plug :accepts, ["json"]
    plug :put_api_spec
  end

  pipeline :session_api do
    # Setup, authentication, and Console JSON requests share cookie and CSRF protection.
    # The v2 Console API uses the JSON:API media type.
    plug :accepts, ["json", "json_api"]
    plug :fetch_session
    plug :browser_csrf
    plug :put_secure_browser_headers
    plug :private_response
  end

  pipeline :oauth_protocol do
    # Public OIDC Client requests use their declared Client authentication.
    plug :fetch_session
    plug :put_secure_browser_headers
    plug :oidc_cors
  end

  pipeline :site_admin do
    plug :put_api_spec
    plug :require_site_admin_session
  end

  pipeline :pod_api do
    plug :accepts, ["json", "event-stream"]
    plug :fetch_session
    plug :browser_csrf
    plug :put_secure_browser_headers
    plug :private_response
    plug :require_pod_session
  end

  pipeline :data_context do
    plug :put_data_context
  end

  pipeline :ai_gateway_json do
    plug :accepts, ["json", "event-stream"]
  end

  pipeline :ai_gateway_api do
    # Runtime AI calls are stateless HTTP requests authenticated as an Agent,
    # an authorized OIDC Human.
    plug :put_api_spec
    plug :oidc_cors
    plug :require_ai_gateway_access_token
  end

  # `/.internal-apis` is the private contract between the SPAs and the server —
  # the setup wizard and sign-in app drive these; they are not a public API.
  scope "/.internal-apis", AnkoleWeb do
    pipe_through :session_api

    get "/oidc-logout/:id", OIDCLogoutController, :confirmation

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
    put "/sessions/active", AuthController, :activate_account
    get "/identity-providers", AuthController, :identity_providers
    post "/sessions/identity-selection", AuthController, :select_identity
    delete "/authentications/current", AuthController, :delete_authentication
    post "/sessions/local-password", AuthController, :local_password_login
    post "/sessions/local-password/change", AuthController, :local_password_change
  end

  scope "/", AnkoleWeb do
    pipe_through :oauth_protocol

    get "/.well-known/openid-configuration", OIDCController, :discovery
    get "/.well-known/jwks.json", OIDCController, :jwks
    get "/oauth/authorize", OIDCController, :authorize
    get "/oauth/authorize/resume", OIDCController, :resume_authorize
    post "/oauth/token", OIDCController, :token
    post "/oauth/introspect", OIDCController, :introspect
    get "/oauth/logout", OIDCLogoutController, :request
    post "/oauth/logout", OIDCLogoutController, :request
    get "/oauth/userinfo", OIDCController, :userinfo
    post "/oauth/userinfo", OIDCController, :userinfo
    options "/oauth/token", OIDCController, :options
    options "/oauth/userinfo", OIDCController, :options
  end

  scope "/.internal-apis/pod", AnkoleWeb do
    pipe_through :pod_api

    get "/realtime-token", PodPageController, :realtime_token
    get "/agents/:uid/model-profiles", PodModelController, :catalog
    get "/conversations/:id/model-profile", PodModelController, :show
    put "/conversations/:id/model-profile", PodModelController, :update
    get "/pages", PodPageController, :index
    post "/pages", PodPageController, :create
    get "/subjects", PodPageController, :subjects
    post "/versions", PodPageController, :reconcile_versions
    get "/space", PodPageController, :space
    put "/space", PodPageController, :set_space
    post "/space/agents", PodPageController, :space_agent
    delete "/space/agents/:uid", PodPageController, :remove_space_agent
    get "/pages/:id/files", PodFileController, :index
    get "/pages/:id/files/content", PodFileController, :download
    post "/pages/:id/files", PodFileController, :upload
    post "/pages/:id/publish", PodFileController, :publish
    get "/pages/:id/routes/*path", PodAppletController, :get
    post "/pages/:id/routes/*path", PodAppletController, :post
    put "/pages/:id/routes/*path", PodAppletController, :put
    patch "/pages/:id/routes/*path", PodAppletController, :patch
    delete "/pages/:id/routes/*path", PodAppletController, :delete
    post "/pages/:id/copy-file", PodFileController, :copy
    get "/pages/:id", PodPageController, :show
    patch "/pages/:id", PodPageController, :update
    delete "/pages/:id", PodPageController, :delete
    post "/pages/:id/move", PodPageController, :move
    post "/pages/:id/restore", PodPageController, :restore
    post "/pages/:id/embeds/:ref/delete", PodPageController, :delete_embed
    put "/pages/:id/content", PodPageController, :write
    put "/pages/:id/user-state", PodPageController, :user_state
    get "/pages/:id/sharing", PodPageController, :sharing
    put "/pages/:id/sharing", PodPageController, :set_sharing
    get "/databases/:page_id", PodDatabaseController, :tables
    post "/databases/:page_id/tables", PodDatabaseController, :create_table
    get "/tables/:id", PodDatabaseController, :show
    post "/tables/:id/query", PodDatabaseController, :query
    post "/tables/:id/aggregate", PodDatabaseController, :aggregate
    post "/tables/:id/records", PodDatabaseController, :write
    post "/tables/:id/fields", PodDatabaseController, :create_field
    patch "/fields/:id", PodDatabaseController, :update_field
    delete "/fields/:id", PodDatabaseController, :delete_field
    post "/tables/:id/views", PodDatabaseController, :create_view
    patch "/views/:id", PodDatabaseController, :update_view
    delete "/views/:id", PodDatabaseController, :delete_view
    post "/tables/:id/copy", PodDatabaseController, :copy
    get "/agents", PodController, :agents
    post "/attachments", PodAttachmentController, :upload
    get "/conversations/:id/attachments/:message_id", PodAttachmentController, :download
    get "/conversations", PodController, :index
    post "/conversations", PodController, :create
    get "/conversations/:id", PodController, :show
    delete "/conversations/:id", PodController, :delete
    post "/conversations/:id/messages", PodController, :post_message
    post "/conversations/:id/queue", PodController, :update_queue
    get "/conversations/:id/events", PodController, :events
  end

  # The spec document is public (no bearer token) so tooling can read it without
  # credentials; the API endpoints it describes still require one below.
  scope "/api/v1" do
    pipe_through :openapi

    get "/openapi.json", OpenAPISpex.Plug.RenderSpec, []
  end

  scope "/api/v1/site", AnkoleWeb do
    pipe_through [:session_api, :site_admin]

    get "/app-configurations", AppConfigurationController, :index
    get "/app-configurations/:key", AppConfigurationController, :show
    put "/app-configurations/:key", AppConfigurationController, :update
    delete "/app-configurations/:key", AppConfigurationController, :delete
    post "/app-configurations/:key/decryptions", AppConfigurationController, :decrypt
    get "/worker-envs", WorkerEnvController, :index
    put "/worker-envs/:name", WorkerEnvController, :update
    delete "/worker-envs/:name", WorkerEnvController, :delete
    post "/worker-envs/:name/decryptions", WorkerEnvController, :decrypt
    get "/control-plane-plugins", ControlPlanePluginController, :index
    put "/control-plane-plugins", ControlPlanePluginController, :update
    get "/worker-provider-kinds", WorkerProviderController, :kinds
    get "/worker-providers", WorkerProviderController, :index
    post "/worker-providers", WorkerProviderController, :create
    patch "/worker-providers/:provider_id", WorkerProviderController, :update
    get "/worker-providers/:provider_id/check", WorkerProviderController, :check
    delete "/worker-providers/:provider_id", WorkerProviderController, :delete
    get "/ai-gateway/models", AIGatewayProviderController, :models
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

    get "/tenants", TenantController, :index
    post "/tenants", TenantController, :create
    patch "/tenants/:tenant_id", TenantController, :update
    delete "/tenants/:tenant_id", TenantController, :delete
    put "/tenants/:tenant_id/suspension", TenantController, :suspend
    delete "/tenants/:tenant_id/suspension", TenantController, :resume
    get "/privileged-tenant", TenantController, :privileged
    put "/privileged-tenant", TenantController, :transfer
  end

  scope "/api/v1", AnkoleWeb do
    pipe_through [:session_api, :site_admin, :data_context]

    get "/app-configurations", AppConfigurationController, :index_tenant
    get "/app-configurations/:key", AppConfigurationController, :show_tenant
    put "/app-configurations/:key", AppConfigurationController, :update_tenant
    delete "/app-configurations/:key", AppConfigurationController, :delete_tenant
    post "/app-configurations/:key/decryptions", AppConfigurationController, :decrypt_tenant

    get "/worker-envs", WorkerEnvController, :index_tenant
    put "/worker-envs/:name", WorkerEnvController, :update_tenant
    delete "/worker-envs/:name", WorkerEnvController, :delete_tenant
    post "/worker-envs/:name/decryptions", WorkerEnvController, :decrypt_tenant

    get "/agents/:agent_uid/worker-envs", WorkerEnvController, :index_for_agent
    put "/agents/:agent_uid/worker-envs/:name", WorkerEnvController, :update_for_agent
    delete "/agents/:agent_uid/worker-envs/:name", WorkerEnvController, :delete_for_agent

    post "/agents/:agent_uid/worker-envs/:name/decryptions",
         WorkerEnvController,
         :decrypt_for_agent

    get "/principals", PrincipalController, :index
    post "/principals", PrincipalController, :create
    get "/work-access-reviews", HumanAccessController, :unresolved_work
    post "/work-access-reviews", HumanAccessController, :classify_work
    get "/principals/:uid/access", HumanAccessController, :show
    post "/principals/:uid/access-disables", HumanAccessController, :disable
    post "/principals/:uid/access-restorations", HumanAccessController, :restore

    post "/principals/:uid/access-restrictions/:restriction_id/clear",
         HumanAccessController,
         :clear_restriction

    post "/principals/:uid/work-cleanup-retries", HumanAccessController, :retry_cleanup
    get "/principals/:uid", PrincipalController, :show
    patch "/principals/:uid", PrincipalController, :update
    get "/principals/:uid/groups", PrincipalController, :groups
    get "/principals/:uid/grants", PrincipalController, :grants

    post "/principals/:uid/local-password-resets",
         PrincipalController,
         :create_local_password_reset

    get "/oidc-clients", OIDCClientController, :index
    post "/oidc-clients", OIDCClientController, :create
    get "/oidc-clients/login-sources", OIDCClientController, :login_sources
    get "/oidc-clients/:id", OIDCClientController, :show
    patch "/oidc-clients/:id", OIDCClientController, :update
    delete "/oidc-clients/:id", OIDCClientController, :delete
    post "/oidc-clients/:id/secret-rotations", OIDCClientController, :rotate_secret
    get "/oidc-clients/:id/logout-deliveries", OIDCClientController, :logout_deliveries

    post "/oidc-clients/:id/logout-deliveries/:delivery_id/retries",
         OIDCClientController,
         :retry_logout

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
    post "/brain/dream", BrainController, :dream
    get "/brain/object-types", BrainController, :object_types
    post "/brain/search-preview", BrainController, :search_preview
    get "/brain/principals/:principal_uid/knowledge", BrainController, :principal_knowledge
    # Object slugs contain `/`, so the object page carries the slug as a query
    # parameter instead of a wildcard path segment, which the OpenAPI document
    # could not express.
    get "/brain/objects/show", BrainController, :show_object

    get "/agents", AgentController, :index
    post "/agents", AgentController, :create
    get "/agents/:agent_uid", AgentController, :show
    patch "/agents/:agent_uid", AgentController, :update
    delete "/agents/:agent_uid", AgentController, :delete
    post "/agents/:agent_uid/enable", AgentController, :enable
    put "/agents/:agent_uid/worker-provider", WorkerProviderController, :assign

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

    get "/agent-workers", AgentWorkerController, :index

    get "/agents/:agent_uid/background-activities/background-jobs",
        BackgroundActivityController,
        :jobs

    get "/agents/:agent_uid/background-activities/workflow",
        BackgroundActivityController,
        :workflow

    get "/agents/:agent_uid/background-activities/automation-runs",
        BackgroundActivityController,
        :automation_runs

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

    get "/agents/:agent_uid/files", AgentFileController, :index
    get "/agents/:agent_uid/files/content", AgentFileController, :download
    post "/agents/:agent_uid/files", AgentFileController, :upload
    post "/agents/:agent_uid/file-moves", AgentFileController, :move
    delete "/agents/:agent_uid/files", AgentFileController, :delete

    get "/agents/:agent_uid/model-profiles", AgentController, :index_model_profiles

    get "/identity-provider-adapters", IdentityProviderController, :adapters
    get "/identity-providers/:provider_id/directory", DirectoryAccessController, :show
    post "/identity-providers/:provider_id/directory-reviews", DirectoryAccessController, :approve

    post "/identity-providers/:provider_id/directory-events/:event_id/reviews",
         DirectoryAccessController,
         :review_event

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

    get "/agents/:agent_uid/token-quota", AgentController, :show_token_quota
    put "/agents/:agent_uid/token-quota", AgentController, :put_token_quota
    delete "/agents/:agent_uid/token-quota", AgentController, :delete_token_quota
    post "/agents/:agent_uid/token-quota/reset", AgentController, :reset_token_quota

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

    get "/conversations/:conversation_id/standing-orders",
        SignalBindingController,
        :show_conversation_standing_orders

    put "/conversations/:conversation_id/standing-orders",
        SignalBindingController,
        :put_conversation_standing_orders

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
    post "/webhook-endpoints", WebhookEndpointController, :create
    delete "/webhook-endpoints/:webhook_endpoint_id", WebhookEndpointController, :cancel

    delete "/agents/:agent_uid/webhook-endpoints/:webhook_endpoint_id",
           WebhookEndpointController,
           :delete

    get "/automation-jobs", AutomationJobController, :index

    get "/agents/:agent_uid/automation-jobs/:automation_job_id",
        AutomationJobController,
        :show
  end

  # The JSON:API routers serve the routes that the Ash domains declare. The site
  # router comes first because the Console router serves all other v2 paths.
  scope "/api/v2/site" do
    pipe_through [:session_api, :site_admin]

    forward "/", AnkoleWeb.JSONAPI.SiteRouter
  end

  scope "/api/v2" do
    pipe_through [:session_api, :site_admin, :data_context]

    forward "/", AnkoleWeb.JSONAPI.ConsoleRouter
  end

  scope "/api/v1/ai-gateway", AnkoleWeb do
    pipe_through :ai_gateway_api

    get "/files/:file_id/content", AIGatewayFilesController, :content
  end

  scope "/api/v1/ai-gateway", AnkoleWeb do
    pipe_through [:ai_gateway_json, :ai_gateway_api]

    options "/*path", AIGatewayController, :options
    get "/models", AIGatewayController, :models
    get "/files", AIGatewayFilesController, :index
    post "/files", AIGatewayFilesController, :create
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

  scope "/signals/v1/cloudevents", AnkoleWeb do
    post "/:token", CloudEventController, :create
  end

  # Provider webhook ingress. Not a RESTful API surface, so it lives outside
  # /api/v1 and outside every pipeline: no session, no CSRF, no bearer token,
  # and no Accept negotiation (providers send arbitrary Accept headers).
  # Authenticating the provider is the declared handler's job — Bot Framework
  # JWT, Graph clientState, or whatever the provider signs with.
  # A provider that verifies its callback URL sends a GET first (Meta's
  # subscription challenge), so the same action serves both methods and the
  # handler reads `method` to tell them apart.
  scope "/webhooks", AnkoleWeb do
    post "/v1/:handler_id/:instance_id/:kind", SignalWebhookController, :handle
    get "/v1/:handler_id/:instance_id/:kind", SignalWebhookController, :handle
  end

  # Browser-facing HTML. The `*path` catch-alls let each SPA own its own
  # client-side routing: console/setup deep links and canonical Pod paths return the same
  # shell, and the React router takes over. SpaController re-checks setup/auth
  # state on every shell request, so the access gate stays server-side rather
  # than trusting the SPA to redirect.
  scope "/", AnkoleWeb do
    pipe_through :browser

    get "/", SpaController, :home
    get "/sessions/new", SpaController, :sessions_new
    get "/oauth/logout/confirm", SpaController, :logout_confirmation
    post "/oauth/logout/confirm", OIDCLogoutController, :confirm
    get "/sessions/logged-out", SpaController, :logged_out
    get "/sessions/oidc/:provider_id/authorization", AuthController, :oidc_authorization
    # The OIDC redirect lands here as a top-level browser navigation (not via the
    # SPA), so it carries the session cookie holding the pending OIDC state.
    get "/sessions/oidc/:provider_id/callback", AuthController, :oidc_callback
    get "/site-admin-console", SpaController, :console
    get "/site-admin-console/*path", SpaController, :console
    get "/pod", SpaController, :pod
    get "/pod/*path", SpaController, :pod
    get "/pages/:id", SpaController, :pod
    get "/conversations/:id", SpaController, :pod
    get "/content/:scope", SpaController, :pod
    get "/setup", SpaController, :setup
    get "/setup/*path", SpaController, :setup
  end

  # Function plugs preserve runtime dependencies on business code in production too.
  defp browser_csrf(conn, opts),
    do: AnkoleWeb.Plugs.BrowserCSRF.call(conn, AnkoleWeb.Plugs.BrowserCSRF.init(opts))

  defp put_api_spec(conn, _opts),
    do: PutAPISpec.call(conn, PutAPISpec.init(module: AnkoleWeb.APISpec))

  defp oidc_cors(conn, opts),
    do: AnkoleWeb.Plugs.OIDCCORS.call(conn, AnkoleWeb.Plugs.OIDCCORS.init(opts))

  defp require_site_admin_session(conn, opts),
    do:
      AnkoleWeb.Plugs.RequireSiteAdminSession.call(
        conn,
        AnkoleWeb.Plugs.RequireSiteAdminSession.init(opts)
      )

  defp require_pod_session(conn, opts),
    do: AnkoleWeb.Plugs.RequirePodSession.call(conn, AnkoleWeb.Plugs.RequirePodSession.init(opts))

  defp put_data_context(conn, opts),
    do: AnkoleWeb.Plugs.PutDataContext.call(conn, AnkoleWeb.Plugs.PutDataContext.init(opts))

  defp require_ai_gateway_access_token(conn, opts),
    do:
      AnkoleWeb.Plugs.RequireAIGatewayAccessToken.call(
        conn,
        AnkoleWeb.Plugs.RequireAIGatewayAccessToken.init(opts)
      )

  defp private_response(conn, _opts),
    do: put_resp_header(conn, "cache-control", "private, no-store")
end
