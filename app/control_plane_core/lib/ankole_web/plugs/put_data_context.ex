defmodule AnkoleWeb.Plugs.PutDataContext do
  @moduledoc "Selects data for an authenticated site administrator's request."
  @behaviour Plug
  import Plug.Conn
  import Phoenix.Controller
  alias Ankole.Repo
  alias Ankole.Tenants.Tenant

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "x-ankole-tenant") do
      [] -> conn
      [id] -> put_context(conn, id)
      _ -> invalid_context(conn)
    end
  end

  defp put_context(conn, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Tenant{deleting_at: nil} = tenant} <- Ankole.Tenants.get_tenant(id) do
      Repo.put_tenant_id(tenant.id)
      conn
    else
      _ -> invalid_context(conn)
    end
  end

  defp invalid_context(conn) do
    conn
    |> put_status(404)
    |> json(%{
      error: %{code: "data_tenant_unavailable", message: "The selected tenant is unavailable"}
    })
    |> halt()
  end
end
