defmodule Ankole.EditionFixture.Router do
  use AnkoleWeb, :router

  pipeline :edition do
    plug :add_authentications
  end

  scope "/" do
    pipe_through :edition
    get "/edition-fixture", Ankole.EditionFixture.Controller, :show
    forward "/", AnkoleWeb.Router
  end

  defp add_authentications(conn, _opts), do: Plug.Conn.assign(conn, :browser_login_mode, :add)
end

defmodule Ankole.EditionFixture.Controller do
  use AnkoleWeb, :controller
  def show(conn, _params), do: text(conn, "SaaS build fixture")
end

defmodule Ankole.EditionFixture.HostPolicy do
  @behaviour AnkoleWeb.Plugs.RequestHost
  def classify(%URI{host: "site.example.test"}), do: {:ok, :site}

  def classify(%URI{host: "pod.example.test"}),
    do: {:ok, {:pod, "019a2b00-0000-7000-8000-000000000001"}}

  def classify(_), do: :error
end

defmodule Ankole.EditionFixture.Config do
  def runtime_config(_env), do: []

  def definitions do
    [
      Ankole.AppConfigure.define(
        key: "fixture.edition",
        scope: :global,
        encrypted: false,
        schema: Ankole.AppConfigure.Schema.string(),
        default_value: "saas"
      )
    ]
  end

  def patterns, do: []
end

defmodule Ankole.EditionFixture.Source do
  @behaviour Ankole.IdentityProviders.SiteSources
  def authenticate(_), do: {:error, :invalid_authentication}
  def display_name, do: "Build fixture"
  def login_path, do: "/edition-fixture"
  def fresh_authentication?, do: false
end
