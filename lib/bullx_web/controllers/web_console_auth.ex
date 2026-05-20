defmodule BullXWeb.WebConsoleAuth do
  @moduledoc """
  Authentication plug for the web console.

  Loads the signed-in principal from the session and assigns it as
  `:current_principal`. Unauthenticated requests are redirected to the login
  page (browser navigations) or answered with `401` (JSON/API requests), so the
  SPA can react without following an HTML redirect.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias BullX.Principals

  def require_login(conn, _opts) do
    case authenticate(conn) do
      {:ok, principal} -> assign(conn, :current_principal, principal)
      :error -> deny(conn)
    end
  end

  defp authenticate(conn) do
    with principal_id when is_binary(principal_id) <- get_session(conn, :principal_id),
         {:ok, %{status: :active} = principal} <- Principals.get_principal(principal_id) do
      {:ok, principal}
    else
      _ -> :error
    end
  end

  defp deny(conn) do
    case get_format(conn) do
      "json" ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "unauthorized"})
        |> halt()

      _ ->
        conn
        |> redirect(to: login_path(conn))
        |> halt()
    end
  end

  defp login_path(conn) do
    return_to =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    "/sessions/new?" <> URI.encode_query(%{return_to: return_to})
  end
end
