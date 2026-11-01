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
    case WebSession.authorize_site_admin_session(conn) do
      {:ok, %{"principal_uid" => uid} = authentication} ->
        with {:ok, tenant} <- Ankole.Tenants.privileged(),
             :ok <- Repo.put_tenant_id(tenant.id),
             {:ok, principal} <- Principals.get_principal(uid) do
          conn
          |> assign(:current_principal_uid, uid)
          |> assign(:current_principal, principal)
          |> assign(
            :authz_actor,
            Ankole.AuthZ.Actor.from_browser(
              principal,
              authentication,
              "console_rest",
              to_string(:inet.ntoa(conn.remote_ip))
            )
          )
        else
          _ ->
            conn
            |> ConsoleErrors.render(401, "unauthorized", "active administrator session required")
            |> halt()
        end

      :forbidden ->
        conn
        |> ConsoleErrors.render(403, "forbidden", "site administrator access required")
        |> halt()

      :unauthorized ->
        conn
        |> ConsoleErrors.render(401, "unauthorized", "active administrator session required")
        |> halt()
    end
  end
end
