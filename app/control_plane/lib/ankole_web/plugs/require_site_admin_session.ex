defmodule AnkoleWeb.Plugs.RequireSiteAdminSession do
  @moduledoc "Authenticates Console API requests with an active administrator browser session."

  import Plug.Conn

  alias Ankole.Repo
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.Session, as: WebSession

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case WebSession.authorize_site_admin_session(conn) do
      {:ok,
       %{
         authentication: %{"principal_uid" => uid} = authentication,
         principal: principal,
         tenant: tenant
       }} ->
        :ok = Repo.put_tenant_id(tenant.id)
        :ok = WebSession.renew_authentication(authentication)

        conn
        |> assign(:current_tenant, tenant)
        |> assign(:current_principal_uid, uid)
        |> assign(:current_principal, principal)
        |> assign(:site_admin_authentication, authentication)
        |> assign(
          :authz_actor,
          Ankole.AuthZ.Actor.from_browser(
            principal,
            authentication,
            "console_rest",
            to_string(:inet.ntoa(conn.remote_ip))
          )
        )

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
