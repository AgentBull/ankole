defmodule BullXWeb.Router do
  use BullXWeb, :router

  import BullXWeb.WebConsoleAuth, only: [require_login: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug Inertia.Plug
    plug :fetch_flash
    plug :put_root_layout, html: {BullXWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: BullXWeb.ApiSpec
  end

  pipeline :health do
    plug :accepts, ["json"]
  end

  pipeline :console_browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {BullXWeb.Layouts, :console}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :require_login
  end

  pipeline :console_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :require_login
  end

  pipeline :internal_api do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
    plug OpenApiSpex.Plug.PutApiSpec, module: BullXWeb.ApiSpec
    plug :require_login
  end

  scope "/", BullXWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/setup", SetupController, :show
    get "/setup/sessions/new", SetupSessionController, :new
    post "/setup/sessions", SetupSessionController, :create
    get "/setup/plugins", SetupPluginsController, :show
    post "/setup/plugins", SetupPluginsController, :update
    get "/setup/llm/providers", SetupLLMController, :show
    get "/setup/llm/models", SetupLLMController, :models
    post "/setup/llm/providers/check", SetupLLMController, :check
    post "/setup/llm/providers", SetupLLMController, :save
    get "/setup/channel-sources", SetupChannelSourcesController, :show
    post "/setup/channel-sources/check", SetupChannelSourcesController, :check

    post "/setup/channel-sources/generated-secret",
         SetupChannelSourcesController,
         :generated_secret

    post "/setup/channel-sources", SetupChannelSourcesController, :save
    get "/setup/ai-agents", SetupAIAgentsController, :show
    post "/setup/ai-agents", SetupAIAgentsController, :save
    get "/setup/event-routing-rules", SetupEventRoutingController, :show
    post "/setup/event-routing-rules", SetupEventRoutingController, :save
    get "/setup/activate-admin", SetupActivationController, :show
    get "/setup/activation/status", SetupActivationController, :status
    get "/sessions/new", SessionController, :new
    post "/sessions/login_auth", SessionController, :login_auth
    delete "/sessions", SessionController, :delete
    get "/sessions/oidc/:provider", SessionController, :oidc
    get "/sessions/oidc/:provider/callback", SessionController, :oidc_callback
  end

  scope "/console", BullXWeb do
    pipe_through :console_api

    get "/api/session", WebConsoleController, :session
  end

  scope "/.internal-apis/v1", BullXWeb.Api do
    pipe_through :internal_api

    get "/channel-adapters", ChannelAdapterController, :index
    get "/channels", ChannelController, :index
    post "/channels", ChannelController, :create
    post "/channels/connectivity-check", ChannelController, :connectivity_check
    get "/channels/:adapter_id/:id", ChannelController, :show
    put "/channels/:adapter_id/:id", ChannelController, :update
    delete "/channels/:adapter_id/:id", ChannelController, :delete
  end

  scope "/console", BullXWeb do
    pipe_through :console_browser

    get "/", WebConsoleController, :index
    get "/*path", WebConsoleController, :index
  end

  scope "/", BullXWeb do
    pipe_through :health

    get "/livez", HealthController, :livez
    get "/readyz", HealthController, :readyz
  end

  scope "/" do
    pipe_through :api

    get "/.well-known/service-desc", OpenApiSpex.Plug.RenderSpec, []
  end

  # Enable Swagger UI in development
  if Application.compile_env(:bullx, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      get "/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/.well-known/service-desc"
    end
  end
end
