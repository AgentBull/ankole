defmodule AnkoleWeb.Router do
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
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Unused by any scope today, but kept as the conventional JSON entry pipeline.
  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :openapi do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: AnkoleWeb.ApiSpec
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
    plug OpenApiSpex.Plug.PutApiSpec, module: AnkoleWeb.ApiSpec
    plug AnkoleWeb.Plugs.RequireConsoleAccessToken
  end

  # `/.internal-apis` is the private contract between the SPAs and the server —
  # the setup wizard and sign-in app drive these; they are not a public API.
  scope "/.internal-apis", AnkoleWeb do
    pipe_through :session_api

    get "/setup/state", SetupController, :state
    post "/setup/sessions", SetupController, :create_session
    delete "/setup/sessions/current", SetupController, :delete_session
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
  scope "/api" do
    pipe_through :openapi

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", AnkoleWeb do
    pipe_through :console_api

    get "/app-configurations", AppConfigurationController, :index
    get "/app-configurations/:key", AppConfigurationController, :show
    put "/app-configurations/:key", AppConfigurationController, :update
    delete "/app-configurations/:key", AppConfigurationController, :delete
    post "/app-configurations/:key/decryptions", AppConfigurationController, :decrypt
  end

  # Browser-facing HTML. The `*path` catch-alls let each SPA own its own
  # client-side routing: any deep link under /console, /setup, or /auth returns
  # the same shell, and the React router takes over. SpaController re-checks
  # setup/auth state on every shell request, so the access gate stays
  # server-side rather than trusting the SPA to redirect.
  scope "/", AnkoleWeb do
    pipe_through :browser

    get "/", SpaController, :home
    get "/sessions/new", SpaController, :sessions_new
    # The OIDC redirect lands here as a top-level browser navigation (not via the
    # SPA), so it carries the session cookie holding the pending OIDC state.
    get "/sessions/oidc/:provider_id/callback", AuthController, :oidc_callback
    get "/auth", SpaController, :auth_redirect
    get "/auth/*path", SpaController, :auth_redirect
    get "/console", SpaController, :console
    get "/console/*path", SpaController, :console
    get "/setup", SpaController, :setup
    get "/setup/*path", SpaController, :setup
  end
end
