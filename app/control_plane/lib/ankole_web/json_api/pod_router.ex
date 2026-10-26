defmodule AnkoleWeb.JSONAPI.PodRouter do
  @moduledoc "The selected Pod's browser API. Domain operations authorize the current human."
  use AnkoleWeb.JSONAPI.Router,
    scope: :pod,
    domains: [Ankole.Pod, AnkoleWeb.MemberAPI],
    prefix: "/api/v2/pod",
    before_dispatch: {__MODULE__, :context, []}

  def context(conn, :open_api), do: Plug.Conn.put_resp_content_type(conn, "application/json")

  def context(conn, route) do
    conn = AnkoleWeb.JSONAPI.Context.before_dispatch(conn, route, :pod)

    if is_map(route) and route.resource == AnkoleWeb.MeOperations,
      do:
        Ash.PlugHelpers.set_context(conn, Map.put(Ash.PlugHelpers.get_context(conn), :conn, conn)),
      else: conn
  end
end
