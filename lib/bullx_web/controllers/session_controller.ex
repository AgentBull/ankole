defmodule BullXWeb.SessionController do
  @moduledoc false

  use BullXWeb, :controller

  @state_salt "principal-login-provider-state"

  def new(conn, params) do
    providers = BullX.Principals.login_provider_ids()

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
      #{provider_links(providers, params)}
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

  def oidc_start(conn, %{"provider" => provider} = params) do
    with {:ok, source, module, _opts} <- BullX.Principals.fetch_login_provider(provider),
         request <- %{
           "return_to" => local_return_to(params["return_to"]),
           "redirect_uri" => callback_url(provider)
         },
         {:ok, %{url: url, state: state}} <- module.authorization_url(source, request),
         {:ok, signed_state} <- sign_state(state) do
      redirect(conn, external: replace_query_param(url, "state", signed_state))
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> html(escape(login_error(reason)))
    end
  end

  def oidc_callback(conn, %{"provider" => provider, "state" => signed_state} = params) do
    with {:ok, state} <- verify_state(signed_state),
         :ok <- ensure_provider(provider, state),
         {:ok, source, module, _opts} <- BullX.Principals.fetch_login_provider(provider),
         {:ok, subject} <- module.callback(source, params, state),
         {:ok, principal, _identity} <-
           BullX.Principals.match_or_create_human_from_login_subject(subject) do
      :telemetry.execute(
        [:bullx, :feishu, :oidc, :callback],
        %{count: 1},
        %{provider: provider, result: :ok}
      )

      conn
      |> put_principal_session(principal.id)
      |> redirect(to: local_return_to(state["return_to"]))
    else
      {:error, reason} ->
        :telemetry.execute(
          [:bullx, :feishu, :oidc, :callback],
          %{count: 1},
          %{provider: provider, result: :error}
        )

        conn
        |> put_status(:unauthorized)
        |> html(escape(login_error(reason)))
    end
  end

  def oidc_callback(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> html("missing OIDC state")
  end

  defp put_principal_session(conn, principal_id) do
    delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:principal_id, principal_id)
  end

  defp sign_state(state) do
    {:ok, Phoenix.Token.sign(BullXWeb.Endpoint, @state_salt, state)}
  end

  defp verify_state(token) when is_binary(token) do
    Phoenix.Token.verify(BullXWeb.Endpoint, @state_salt, token,
      max_age: Feishu.Config.oidc_state_ttl_seconds!()
    )
  end

  defp ensure_provider(provider, state) do
    case state["provider"] == provider do
      true -> :ok
      false -> {:error, :provider_mismatch}
    end
  end

  defp callback_url(provider) do
    BullXWeb.Endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/sessions/oidc/#{URI.encode(provider)}/callback")
  end

  defp replace_query_param(url, key, value) do
    uri = URI.parse(url)

    query =
      uri.query
      |> Kernel.||("")
      |> URI.decode_query()
      |> Map.put(key, value)
      |> URI.encode_query()

    %{uri | query: query}
    |> URI.to_string()
  end

  defp provider_links([], _params), do: ""

  defp provider_links(providers, params) do
    return_to = URI.encode_query(%{"return_to" => local_return_to(params["return_to"])})

    providers
    |> Enum.map(fn provider ->
      ~s(<p><a href="/sessions/oidc/#{URI.encode(provider)}?#{return_to}">#{escape(provider)}</a></p>)
    end)
    |> Enum.join("\n")
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
