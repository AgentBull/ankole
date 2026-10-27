defmodule AnkoleWeb.Router do
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
    plug :require_site_admin_session
  end

  pipeline :pod_api do
    plug :accepts, ["json", "json_api", "event-stream"]
    plug :fetch_session
    plug :browser_csrf
    plug :put_secure_browser_headers
    plug :private_response
    plug :require_pod_session
  end

  pipeline :applet_frame do
    plug :fetch_session
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
    plug :oidc_cors
    plug :require_ai_gateway_access_token
  end

  scope "/api/v2/browser" do
    pipe_through :session_api
    AnkoleWeb.runtime_forward("/", AnkoleWeb.JSONAPI.BrowserRouter)
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

  scope "/api/v2/pod", AnkoleWeb do
    pipe_through :pod_api

    get "/pages/:id/files/content", PodFileController, :download
    post "/pages/:id/files", PodFileController, :upload
    post "/file-pages", PodFileController, :create
    get "/pages/:id/routes/*path", PodAppletController, :get
    post "/pages/:id/routes/*path", PodAppletController, :post
    put "/pages/:id/routes/*path", PodAppletController, :put
    patch "/pages/:id/routes/*path", PodAppletController, :patch
    delete "/pages/:id/routes/*path", PodAppletController, :delete
    post "/attachments", PodAttachmentController, :upload
    get "/conversations/:id/attachments/:message_id", PodAttachmentController, :download
    get "/conversations/:id/events", PodStreamController, :events
  end

  scope "/api/v2/pod" do
    pipe_through :pod_api
    AnkoleWeb.runtime_forward("/", AnkoleWeb.JSONAPI.PodRouter)
  end

  # Native file transfers use the same browser and tenant protection as Console operations.
  scope "/api/v2", AnkoleWeb do
    pipe_through([:session_api, :site_admin, :data_context])

    get("/agents/:agent_uid/files/content", AgentFileController, :download)
    post("/agents/:agent_uid/files", AgentFileController, :upload)
  end

  # The JSON:API routers serve the routes that the Ash domains declare. The site
  # router comes first because the Console router serves all other v2 paths.
  scope "/api/v2/site" do
    pipe_through [:session_api, :site_admin]

    AnkoleWeb.runtime_forward("/", AnkoleWeb.JSONAPI.SiteRouter)
  end

  scope "/api/v2" do
    pipe_through [:session_api, :site_admin, :data_context]

    AnkoleWeb.runtime_forward("/", AnkoleWeb.JSONAPI.ConsoleRouter)
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

  scope "/", AnkoleWeb do
    pipe_through :applet_frame

    get "/pod/applet-frame/:authentication_ref/:id/:revision/*path",
        PodAppletFrameController,
        :show
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
    get "/join/:token", SpaController, :join
    get "/oauth/logout/confirm", SpaController, :logout_confirmation
    post "/oauth/logout/confirm", OIDCLogoutController, :confirm
    get "/sessions/logged-out", SpaController, :logged_out
    get "/sessions/oidc/:provider_id/authorization", AuthController, :oidc_authorization
    # The OIDC redirect lands here as a top-level browser navigation (not via the
    # SPA), so it carries the session cookie holding the pending OIDC state.
    get "/sessions/oidc/:provider_id/callback", AuthController, :oidc_callback
    get "/site-admin-console", SpaController, :console
    get "/site-admin-console/*path", SpaController, :console
    get "/settings", SpaController, :pod
    get "/me", SpaController, :pod
    get "/pod", SpaController, :pod
    get "/pod/*path", SpaController, :pod
    get "/pages/:id", SpaController, :pod
    get "/conversations/:id", SpaController, :pod
    get "/content/:scope", SpaController, :pod
    get "/setup", SpaController, :setup
    get "/setup/*path", SpaController, :setup
  end

  if Application.compile_env(:ankole, :dev_routes, false) do
    pipeline :dev_mailbox do
      plug :put_secure_browser_headers
      plug :private_response
    end

    scope "/dev" do
      pipe_through :dev_mailbox

      AnkoleWeb.runtime_forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end

  # Function plugs preserve runtime dependencies on business code in production too.
  defp browser_csrf(conn, opts),
    do: AnkoleWeb.Plugs.BrowserCSRF.call(conn, AnkoleWeb.Plugs.BrowserCSRF.init(opts))

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
