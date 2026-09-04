defmodule AnkoleWeb.Plugs.OIDCCORS do
  @moduledoc """
  Allows browser API calls only from origins projected from active OIDC Clients.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Ankole.OIDC

  @behaviour Plug

  @allow_headers "authorization, content-type"
  @allow_methods "DELETE, GET, POST, OPTIONS"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] ->
        conn

      [origin] ->
        if origin == request_origin(conn) or origin in OIDC.active_origins() do
          conn
          |> put_resp_header("access-control-allow-origin", origin)
          |> put_resp_header("vary", merge_vary(get_resp_header(conn, "vary"), "Origin"))
          |> maybe_complete_preflight()
        else
          forbidden(conn)
        end

      _multiple ->
        forbidden(conn)
    end
  end

  defp maybe_complete_preflight(%{method: "OPTIONS"} = conn) do
    conn
    |> put_resp_header("access-control-allow-headers", @allow_headers)
    |> put_resp_header("access-control-allow-methods", @allow_methods)
    |> put_resp_header("access-control-max-age", "600")
    |> send_resp(204, "")
    |> halt()
  end

  defp maybe_complete_preflight(conn), do: conn

  defp forbidden(conn) do
    conn
    |> put_status(403)
    |> json(%{error: %{code: "origin_not_allowed", message: "Origin is not registered"}})
    |> halt()
  end

  defp request_origin(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end

  defp merge_vary([], value), do: value

  defp merge_vary(values, value) do
    values
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Kernel.++([value])
    |> Enum.uniq()
    |> Enum.join(", ")
  end
end
