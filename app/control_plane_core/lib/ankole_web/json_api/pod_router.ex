defmodule AnkoleWeb.JSONAPI.PodRouter do
  @moduledoc "The selected Pod's browser API. Domain operations authorize the current human."
  use AnkoleWeb.JSONAPI.Router,
    scope: :pod,
    domains: [Ankole.Pod],
    prefix: "/api/v2/pod",
    before_dispatch: {__MODULE__, :context, []}

  def context(conn, :open_api), do: Plug.Conn.put_resp_content_type(conn, "application/json")

  def context(conn, _route) do
    conn
    |> Ash.PlugHelpers.set_tenant(Ankole.Repo.tenant_id!())
    |> Ash.PlugHelpers.set_actor(conn.assigns.current_principal)
    |> Ash.PlugHelpers.set_context(%{
      authentication_ref: AnkoleWeb.Session.authentication_reference(conn)
    })
  end
end
