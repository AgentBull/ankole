defmodule AnkoleWeb.Plugs.RequireSiteAdminSession do
  @moduledoc "Authenticates Console API requests with an active administrator browser session."

  import Plug.Conn

  alias Ankole.Repo
  alias Ankole.Principals
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.Session, as: WebSession

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with %{"principal_uid" => uid} <- WebSession.site_admin_session(conn),
         {:ok, principal} <- Repo.across_tenants(fn -> Principals.get_principal(uid) end),
         :ok <- Repo.put_tenant_id(principal.tenant_id) do
      conn
      |> assign(:current_principal_uid, uid)
      |> assign(:current_principal, principal)
    else
      _inactive ->
        conn
        |> ConsoleErrors.render(401, "unauthorized", "active administrator session required")
        |> halt()
    end
  end
end
