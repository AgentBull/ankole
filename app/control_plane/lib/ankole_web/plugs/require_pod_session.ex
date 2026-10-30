defmodule AnkoleWeb.Plugs.RequirePodSession do
  @moduledoc "Authenticates the selected Human and tenant for Pod work."
  @behaviour Plug
  import Plug.Conn
  alias Ankole.Repo
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.Session, as: WebSession

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, true} <- Ankole.Setup.Config.completed?(),
         {:ok, tenant} <- target_tenant(conn),
         :ok <- Repo.put_tenant_id(tenant.id),
         %{"principal_uid" => uid} = authentication <- WebSession.pod_session(conn),
         {:ok, %{type: :human} = principal} <- Ankole.Principals.get_principal(uid) do
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
      _ ->
        conn |> ConsoleErrors.render(401, "unauthorized", "active Pod session required") |> halt()
    end
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
