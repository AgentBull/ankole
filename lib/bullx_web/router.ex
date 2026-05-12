defmodule BullXWeb.Router do
  use BullXWeb, :router

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

  scope "/", BullXWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/setup", SetupController, :show
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

  # Enable Swoosh mailbox preview and Swagger UI in development
  if Application.compile_env(:bullx, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
      get "/swaggerui", OpenApiSpex.Plug.SwaggerUI, path: "/.well-known/service-desc"
    end
  end
end
