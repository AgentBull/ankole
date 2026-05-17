defmodule BullXWeb.SessionController do
  @moduledoc false

  use BullXWeb, :controller

  @oidc_state_salt "principal_login_provider_state"

  def new(conn, params) do
    return_to = local_return_to(params["return_to"])
    providers = provider_links(return_to)

    html(
      conn,
      """
      <!doctype html>
      <html>
      <body>
      <form method="post" action="/sessions/login_auth">
        <input name="_csrf_token" type="hidden" value="#{get_csrf_token()}">
        <input name="return_to" type="hidden" value="#{escape(return_to)}">
        <input name="code" autocomplete="one-time-code">
        <button type="submit">Sign in</button>
      </form>
      #{providers}
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

  def oidc(conn, %{"provider" => provider} = params) do
    redirect_uri = url(~p"/sessions/oidc/#{provider}/callback")

    request = %{
      "return_to" => local_return_to(params["return_to"]),
      "redirect_uri" => redirect_uri
    }

    case BullX.Principals.LoginProviders.authorization_url(provider, request) do
      {:ok, %{url: url, state: %{"nonce" => nonce} = state}} ->
        token = Phoenix.Token.sign(conn, @oidc_state_salt, state)

        conn
        |> put_session(state_session_key(provider, nonce), token)
        |> redirect(external: url)

      {:ok, _result} ->
        conn
        |> put_status(:bad_gateway)
        |> html("login provider returned invalid state")

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> html(escape(login_error(reason)))
    end
  end

  def oidc(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> html("missing provider")
  end

  def oidc_callback(conn, %{"provider" => provider, "state" => nonce} = params) do
    session_key = state_session_key(provider, nonce)

    with {:ok, token} <- session_token(conn, session_key),
         {:ok, state} <-
           Phoenix.Token.verify(conn, @oidc_state_salt, token,
             max_age: BullX.Principals.LoginProviders.state_ttl_seconds(provider)
           ),
         {:ok, subject} <- BullX.Principals.LoginProviders.callback(provider, params, state),
         {:ok, principal, _identity} <-
           BullX.Principals.match_or_create_human_from_login_subject(subject) do
      conn
      |> delete_session(session_key)
      |> put_principal_session(principal.id)
      |> redirect(to: local_return_to(state["return_to"]))
    else
      {:error, reason} ->
        conn
        |> delete_session(session_key)
        |> put_status(:unauthorized)
        |> html(escape(login_error(reason)))
    end
  end

  def oidc_callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> html("missing oidc callback state")
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

  defp provider_links(return_to) do
    case BullX.Principals.login_provider_ids() do
      [] ->
        ""

      providers ->
        links =
          Enum.map_join(providers, "\n", fn provider ->
            query = URI.encode_query(%{"return_to" => return_to})
            href = "/sessions/oidc/#{URI.encode(provider)}?#{query}"
            "<p><a href=\"#{escape(href)}\">Continue with #{escape(provider)}</a></p>"
          end)

        "<section>#{links}</section>"
    end
  end

  defp session_token(conn, key) do
    case get_session(conn, key) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _value -> {:error, :invalid_or_expired_code}
    end
  end

  defp state_session_key(provider, nonce) do
    "oidc_state:#{provider}:#{nonce}"
  end

  defp login_error(reason) do
    case reason do
      :not_found -> "login provider is not configured"
      :not_bound -> "principal is not bound"
      :principal_disabled -> "principal is disabled"
      :not_human -> "principal is not human"
      :invalid_or_expired_code -> "login code is invalid or expired"
      %{"message" => message} when is_binary(message) -> message
      {:invalid, _reason} -> "login state is invalid or expired"
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
