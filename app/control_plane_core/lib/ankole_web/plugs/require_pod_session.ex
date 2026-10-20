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
         {:ok, tenant_id} <- target_tenant(conn),
         :ok <- Repo.put_tenant_id(tenant_id),
         %{"principal_uid" => uid} = authentication <- WebSession.pod_session(conn),
         {:ok, principal} <- Ankole.Principals.get_principal(uid) do
      conn
      |> assign(:current_principal_uid, uid)
      |> assign(:current_principal, principal)
      |> assign(:pod_authentication, authentication)
    else
      _ ->
        conn |> ConsoleErrors.render(401, "unauthorized", "active Pod session required") |> halt()
    end
  end

  def target_tenant(conn) do
    with {:ok, explicit} <- explicit_tenant(conn) do
      case {Repo.tenant_id(), explicit} do
        {host, tenant} when is_binary(host) and is_binary(tenant) and host != tenant ->
          {:error, :tenant_mismatch}

        {host, _} when is_binary(host) ->
          resolve(host)

        {nil, tenant} when is_binary(tenant) ->
          resolve(tenant)

        {nil, nil} ->
          current_or_default(conn)
      end
    end
  end

  defp explicit_tenant(conn) do
    case {get_req_header(conn, "x-ankole-pod"), WebSession.param(conn, "tenant_id")} do
      {[], nil} -> {:ok, nil}
      {[], id} -> cast(id)
      {[id], nil} -> cast(id)
      {[id], id} -> cast(id)
      _ -> {:error, :tenant_mismatch}
    end
  end

  defp current_or_default(conn) do
    case Ankole.BrowserSessions.get(WebSession.browser_reference(conn)) do
      {:ok, %{active_tenant_id: id}} when is_binary(id) ->
        if Ankole.BrowserSessions.current_reference(WebSession.browser_reference(conn)),
          do: resolve(id),
          else: default_tenant()

      _ ->
        default_tenant()
    end
  end

  defp default_tenant,
    do: with({:ok, tenant} <- Ankole.Tenants.privileged(), do: {:ok, tenant.id})

  defp cast(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp resolve(id) do
    with {:ok, %{suspended_at: nil, deleting_at: nil} = tenant} <- Ankole.Tenants.get(id),
         do: {:ok, tenant.id},
         else: (_ -> {:error, :not_found})
  end
end
