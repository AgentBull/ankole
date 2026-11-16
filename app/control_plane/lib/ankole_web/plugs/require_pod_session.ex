defmodule AnkoleWeb.Plugs.RequirePodSession do
  @moduledoc "Authenticates the selected Human and tenant for Pod work via browser session or OIDC Bearer token."
  @behaviour Plug
  import Plug.Conn
  alias Ankole.{OIDC, Repo}
  alias Ankole.OIDC.Tokens
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.Session, as: WebSession

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      [] ->
        call_cookie_session(conn)

      ["Bearer " <> token] when token != "" ->
        call_bearer_session(conn, token)

      _invalid ->
        unauthorized(conn)
    end
  end

  defp call_cookie_session(conn) do
    with {:ok, true} <- Ankole.Setup.Config.completed?(),
         {:ok, tenant} <- target_tenant(conn),
         :ok <- Repo.put_tenant_id(tenant.id),
         {%{"principal_uid" => uid} = authentication, %{type: :human} = principal} <-
           WebSession.pod_session_with_principal(conn) do
      :ok = WebSession.renew_authentication(authentication)

      conn
      |> assign(:current_tenant, tenant)
      |> assign(:current_principal_uid, uid)
      |> assign(:current_principal, principal)
      |> assign(:pod_authentication, authentication)
      |> assign(
        :authz_actor,
        Ankole.AuthZ.Actor.from_browser(
          principal,
          authentication,
          "pod_browser",
          to_string(:inet.ntoa(conn.remote_ip))
        )
      )
    else
      _ -> unauthorized(conn)
    end
  end

  defp call_bearer_session(conn, token) do
    with {:ok, true} <- Ankole.Setup.Config.completed?(),
         {:ok, tenant} <- target_tenant(conn),
         :ok <- valid_bearer_applet_frame?(conn),
         {:ok,
          %{
            claims: claims,
            client: client,
            session: session,
            principal: %{type: :human, status: :active} = principal
          }} <-
           Tokens.verify_pod_access(token),
         true <- client.tenant_id == tenant.id,
         :ok <- Repo.put_tenant_id(tenant.id),
         {:ok, actor} <-
           OIDC.actor_for_session(session, principal, to_string(:inet.ntoa(conn.remote_ip))) do
      conn
      |> assign(:current_tenant, tenant)
      |> assign(:current_principal_uid, principal.uid)
      |> assign(:current_principal, principal)
      |> assign(:oidc_session, session)
      |> assign(:oidc_client, client)
      |> assign(:oidc_claims, claims)
      |> assign(:authz_actor, actor)
      |> Ash.PlugHelpers.set_actor(actor)
    else
      _ -> unauthorized(conn)
    end
  end

  defp valid_bearer_applet_frame?(conn) do
    case conn.path_info do
      ["pod", "applet-frame", ref | _] when ref not in ["current", "oauth"] ->
        {:error, :invalid_authentication_ref}

      _ ->
        :ok
    end
  end

  defp unauthorized(conn) do
    conn |> ConsoleErrors.render(401, "unauthorized", "active Pod session required") |> halt()
  end

  def target_tenant(conn) do
    with host when is_binary(host) <- Repo.tenant_id() || {:error, :not_found},
         {:ok, ^host} <- WebSession.request_tenant(conn, WebSession.param(conn, "tenant_id")) do
      resolve(host)
    end
  end

  defp resolve(id) do
    with {:ok, tenant} <- Ankole.Tenants.get(id),
         true <- Ankole.Tenants.accepting_work?(tenant),
         do: {:ok, tenant},
         else: (_ -> {:error, :not_found})
  end
end
