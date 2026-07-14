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
    get "/setup/identity-provider-adapters", SetupController, :identity_provider_adapters
    put "/setup/identity-providers/:provider_id", SetupController, :put_identity_provider

    post "/setup/identity-providers/:provider_id/oidc/authorizations",
         SetupController,
         :oidc_authorization

    get "/session", AuthController, :session
    delete "/session", AuthController, :delete_session
    post "/oauth/token", AuthController, :oauth_token
    get "/identity-providers", AuthController, :identity_providers

    post "/identity-providers/:provider_id/oidc/authorizations",
         AuthController,
         :oidc_authorization
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

    get "/agents", AgentController, :index
    post "/agents", AgentController, :create
    get "/agents/:agent_uid", AgentController, :show
    patch "/agents/:agent_uid", AgentController, :update
    delete "/agents/:agent_uid", AgentController, :delete

    get "/agent-computer-workers", AgentComputerWorkerController, :index

    get "/delegations", SubagentDelegationController, :index
    get "/delegations/:delegation_id", SubagentDelegationController, :show
    post "/delegations/:delegation_id/cancel", SubagentDelegationController, :cancel

    get "/brain/entries", BrainController, :index
    get "/brain/entries/:id", BrainController, :show
    post "/brain/entry-operations", BrainController, :apply_operations
    get "/brain/audit-log", BrainController, :audit_index
    get "/brain/entries/:id/audit-log", BrainController, :audit_log
    get "/brain/sources/:document_id", BrainController, :source
    post "/brain/audit-log/restorations", BrainController, :restore_audits
    post "/brain/audit-log/:audit_id/restorations", BrainController, :restore_audit
    post "/brain/dreaming-runs", BrainController, :run_dreaming
    get "/brain/dreaming-fitness", BrainController, :dreaming_fitness

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
    put "/ai-gateway/providers/:provider_id", AIGatewayProviderController, :put_provider
    delete "/ai-gateway/providers/:provider_id", AIGatewayProviderController, :delete_provider

    get "/codex-accounts", CodexAccountController, :index
    post "/codex-accounts", CodexAccountController, :create
    put "/codex-accounts/:account_id", CodexAccountController, :update
    delete "/codex-accounts/:account_id", CodexAccountController, :delete
    get "/agents/:agent_uid/model-profiles", AgentController, :index_model_profiles

    get "/identity-provider-adapters", IdentityProviderController, :adapters
    get "/identity-providers", IdentityProviderController, :index
    put "/identity-providers/:provider_id", IdentityProviderController, :put_provider
    post "/identity-providers/:provider_id/sync-runs", IdentityProviderController, :run_sync

    put "/agents/:agent_uid/model-profiles/:profile",
        AgentController,
        :put_model_profile

    delete "/agents/:agent_uid/model-profiles/:profile",
           AgentController,
           :delete_model_profile

    get "/signal-adapters", SignalBindingController, :adapters

    get "/agents/:agent_uid/signal-bindings", SignalBindingController, :index

    put "/agents/:agent_uid/signal-bindings/:adapter_id/:binding_name",
        SignalBindingController,
        :put_binding

    delete "/agents/:agent_uid/signal-bindings/:binding_name",
           SignalBindingController,
           :delete

    get "/agents/:agent_uid/sessions/:session_id/cron-schedules",
        ScheduleController,
        :index_cron

    post "/agents/:agent_uid/sessions/:session_id/cron-schedules",
         ScheduleController,
         :create_cron

    get "/agents/:agent_uid/sessions/:session_id/cron-schedules/:cron_schedule_id",
        ScheduleController,
        :show_cron

    patch "/agents/:agent_uid/sessions/:session_id/cron-schedules/:cron_schedule_id",
          ScheduleController,
          :update_cron

    post "/agents/:agent_uid/sessions/:session_id/cron-schedules/:cron_schedule_id/pause",
         ScheduleController,
         :pause_cron

    post "/agents/:agent_uid/sessions/:session_id/cron-schedules/:cron_schedule_id/resume",
         ScheduleController,
         :resume_cron

    delete "/agents/:agent_uid/sessions/:session_id/cron-schedules/:cron_schedule_id",
           ScheduleController,
           :remove_cron

    post "/agents/:agent_uid/sessions/:session_id/cron-schedules/:cron_schedule_id/runs",
         ScheduleController,
         :run_cron

    get "/agents/:agent_uid/sessions/:session_id/cron-schedules/:cron_schedule_id/runs",
        ScheduleController,
        :cron_runs

    get "/agents/:agent_uid/sessions/:session_id/checkbacks",
        ScheduleController,
        :index_checkbacks

    delete "/agents/:agent_uid/sessions/:session_id/checkbacks/:scheduled_event_id",
           ScheduleController,
           :cancel_checkback
  end

  scope "/api/v1/ai-gateway", AnkoleWeb do
    pipe_through :ai_gateway_api

    get "/models", AIGatewayController, :models
    get "/web_tools", AIGatewayController, :web_tools
    get "/responses", AIGatewayWebSocketController, :responses
    get "/responses/:response_id", AIGatewayController, :retrieve_response
    post "/responses/compact", AIGatewayController, :compact_response
    post "/responses", AIGatewayController, :responses
    post "/embeddings", AIGatewayController, :embeddings
    post "/rerank", AIGatewayController, :rerank
    post "/web_search", AIGatewayController, :web_search
    post "/web_fetch", AIGatewayController, :web_fetch
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
    # The OIDC redirect lands here as a top-level browser navigation (not via the
    # SPA), so it carries the session cookie holding the pending OIDC state.
    get "/sessions/oidc/:provider_id/callback", AuthController, :oidc_callback
    get "/console", SpaController, :console
    get "/console/*path", SpaController, :console
    get "/setup", SpaController, :setup
    get "/setup/*path", SpaController, :setup
  end
end
