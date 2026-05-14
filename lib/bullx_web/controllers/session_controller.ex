defmodule BullXWeb.SessionController do
  @moduledoc false

  use BullXWeb, :controller

  def new(conn, _params) do
    html(
      conn,
      """
      <!doctype html>
      <html>
      <body>
      <form method="post" action="/sessions/login_auth">
        <input name="_csrf_token" type="hidden" value="#{get_csrf_token()}">
        <input name="code" autocomplete="one-time-code">
        <button type="submit">Sign in</button>
      </form>
      </body>
      </html>
      """
    )
  end

  def login_auth(conn, %{"code" => code} = params) do
    case BullX.Principals.consume_login_auth_code(code) do
      {:ok, principal} ->
        conn
        |> put_principal_session(principal.id)
        |> redirect(to: local_return_to(params["return_to"]))

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> html(escape(login_error(reason)))
    end
  end

  def login_auth(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> html("missing login code")
  end

  defp put_principal_session(conn, principal_id) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:principal_id, principal_id)
  end

  defp local_return_to(nil), do: "/"
  defp local_return_to("/" <> _path = value), do: value
  defp local_return_to(_value), do: "/"

  defp login_error(reason) do
    case reason do
      :not_bound -> "principal is not bound"
      :principal_disabled -> "principal is disabled"
      :not_human -> "principal is not human"
      :invalid_or_expired_code -> "login code is invalid or expired"
      %{"message" => message} when is_binary(message) -> message
      _other -> "login failed"
    end
  end

  defp escape(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
