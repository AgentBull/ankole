defmodule AnkoleWeb.Plugs.BrowserCSRF do
  @moduledoc "Checks CSRF against the selected authentication or the ceremony session."
  @behaviour Plug
  import Plug.Conn
  alias AnkoleWeb.Session, as: WebSession

  @impl Plug
  def init(opts), do: Plug.CSRFProtection.init(opts)

  @impl Plug
  def call(conn, fallback) do
    case WebSession.csrf_state(conn) do
      state when is_binary(state) ->
        Plug.CSRFProtection.delete_csrf_token()
        :ok = Plug.CSRFProtection.load_state(conn.secret_key_base, state)

        if protected?(conn) and not valid_request?(conn, state),
          do: raise(Plug.CSRFProtection.InvalidCSRFTokenError)

        register_before_send(conn, fn conn ->
          Plug.CSRFProtection.delete_csrf_token()
          :ok = Plug.CSRFProtection.load_state(nil, nil)
          conn
        end)

      nil ->
        if protected?(conn) and not same_origin?(conn),
          do: raise(Plug.CSRFProtection.InvalidCSRFTokenError)

        Plug.CSRFProtection.call(conn, fallback)
    end
  end

  defp protected?(conn),
    do:
      conn.method not in ["GET", "HEAD", "OPTIONS"] and
        conn.private[:plug_skip_csrf_protection] != true

  defp valid_request?(conn, state) do
    header = List.first(get_req_header(conn, "x-csrf-token"))
    body = if is_non_struct_map(conn.body_params), do: conn.body_params["_csrf_token"]

    (Plug.CSRFProtection.valid_state_and_csrf_token?(state, header) or
       Plug.CSRFProtection.valid_state_and_csrf_token?(state, body)) and same_origin?(conn)
  end

  defp same_origin?(conn) do
    origin =
      URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})

    get_req_header(conn, "origin") in [[], [origin]]
  end
end
