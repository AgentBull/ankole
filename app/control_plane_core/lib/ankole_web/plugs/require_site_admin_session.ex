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
         {:ok, tenant_id} <- Principals.resolve_tenant(uid),
         :ok <- Repo.put_tenant_id(tenant_id),
         {:ok, principal} <- Principals.get_principal(uid) do
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
