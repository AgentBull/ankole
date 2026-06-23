defmodule AnkoleWeb.Router do
  @moduledoc """
  Routes the Phoenix shell, setup API, and admin auth API.

  Phoenix owns browser/session protection here. Application screens are still
  rendered by the SPAs mounted by `AnkoleWeb.SpaController`.
  """

  use AnkoleWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :session_api do
    # JSON endpoints that mutate setup or auth state still use the browser
    # session and CSRF protection. They are API-shaped, not public stateless APIs.
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/api", AnkoleWeb do
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
    get "/identity-providers", AuthController, :identity_providers

    post "/identity-providers/:provider_id/oidc/authorizations",
         AuthController,
         :oidc_authorization
  end

  scope "/", AnkoleWeb do
    pipe_through :browser

    get "/", SpaController, :home
    get "/auth/oidc/:provider_id/callback", AuthController, :oidc_callback
    get "/auth", SpaController, :auth
    get "/auth/*path", SpaController, :auth
    get "/console", SpaController, :console
    get "/console/*path", SpaController, :console
    get "/setup", SpaController, :setup
    get "/setup/*path", SpaController, :setup
  end

  # Other scopes may use custom stacks.
  # scope "/api", AnkoleWeb do
  #   pipe_through :api
  # end
end
