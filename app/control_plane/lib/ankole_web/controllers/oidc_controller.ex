defmodule AnkoleWeb.OIDCController do
  @moduledoc """
  Serves Ankole's OAuth 2.0 and OpenID Connect protocol endpoints.

  The token endpoint uses the declared OIDC Client credentials. It does not
  use the browser session.
  """

  use AnkoleWeb, :controller

  alias Ankole.BrowserSessions
  alias Ankole.OIDC
  alias Ankole.OIDC.{ClientAuthentication, Grants, LoginPolicy}
  alias AnkoleWeb.Session, as: WebSession

  def discovery(conn, _params), do: json(conn, OIDC.discovery_metadata())

  def jwks(conn, _params), do: json(conn, Attesto.JWKS.from_config(OIDC.attesto_config()))

  def authorize(conn, params) do
    params = Map.delete(params, "selection_confirmed")

    with {:ok, client, params} <- OIDC.authorization_request(params) do
      continue_authorization(conn, params, client)
    else
      {:error, {:direct, reason}} ->
        oauth_json_error(conn, 400, "invalid_request", message(reason))

      {:error, {:redirect, error}} ->
        redirect_authorization_error(conn, params, error.error, error.error_description)

      {:error, code, description} ->
        redirect_authorization_error(conn, params, code, description)
    end
  end

  def resume_authorize(conn, %{"flow" => flow}) do
    result =
      BrowserSessions.consume_authorization(
        WebSession.browser_reference(conn),
        flow,
        authorization_reference(conn, flow),
        fn params, auth ->
          with {:ok, client, params} <- OIDC.authorization_request(params),
               :ok <- LoginPolicy.authorize_source(client, auth["provider_id"]),
               :ok <- LoginPolicy.completed_authentication_allowed?(auth, params),
               :ok <- Grants.gateway(client.id, auth["principal_uid"], params["scope"]),
               {:ok, code} <- Grants.authorize_in_tx(params, auth) do
            {:ok, authorization_redirect(conn, params, code)}
          end
        end
      )

    case result do
      {:ok, conn} ->
        conn

      _ ->
        oauth_json_error(
          conn,
          400,
          "invalid_request",
          "authorization request expired or no longer allowed"
        )
    end
  end

  def resume_authorize(conn, _params),
    do: oauth_json_error(conn, 400, "invalid_request", "authorization transaction is required")

  def token(conn, params) do
    with :ok <- Grants.validate_type(params),
         {:ok, client} <- ClientAuthentication.authenticate(conn, params),
         :ok <- authorize_request_origin(conn, client.id),
         {:ok, payload} <- Grants.exchange(client, params) do
      conn |> no_store() |> json(payload)
    else
      {:error, :origin_not_allowed} ->
        token_json_error(conn, 400, "invalid_request", "Origin is not registered for this Client")

      {:error, code, description} ->
        token_json_error(conn, 400, code, description)
    end
  end

  def introspect(conn, params) do
    with {:ok, client} <- ClientAuthentication.authenticate(conn, params, true),
         token when is_binary(token) and token != "" <- params["token"],
         {:ok, response} <- Ankole.OIDC.Introspection.check(token, client) do
      conn |> no_store() |> json(response)
    else
      nil ->
        oauth_json_error(conn, 400, "invalid_request", "token is required")

      "" ->
        oauth_json_error(conn, 400, "invalid_request", "token is required")

      {:error, :temporarily_unavailable} ->
        oauth_json_error(
          conn,
          503,
          "temporarily_unavailable",
          "authentication dependency unavailable"
        )

      _ ->
        conn
        |> put_resp_header("www-authenticate", "Basic realm=\"OIDC introspection\"")
        |> oauth_json_error(401, "invalid_client", "confidential Client authentication required")
    end
  end

  def userinfo(conn, params) do
    case Ankole.OIDC.UserInfo.fetch(conn, params) do
      {:ok, claims} ->
        conn |> no_store() |> json(claims)

      {:error, :origin_not_allowed} ->
        oauth_json_error(conn, 403, "invalid_request", "Origin is not registered for this Client")

      _ ->
        oauth_json_error(conn, 401, "invalid_token", "access token is invalid")
    end
  end

  def options(conn, _params), do: send_resp(conn, 204, "")

  defp authorization_redirect(conn, params, code) do
    values =
      %{"code" => code, "state" => params["state"]}
      |> Map.reject(fn {_, value} -> is_nil(value) end)

    redirect(conn, external: append_query(params["redirect_uri"], URI.encode_query(values)))
  end

  defp continue_authorization(conn, params, client) do
    case {Ankole.Tenants.accepting_work?(client.tenant_id),
          current_resource_owner(conn, client, params)} do
      {false, _} ->
        redirect_authorization_error(conn, params, "access_denied", "Pod is unavailable")

      {true, {:ok, resource_owner, conn}} ->
        with :ok <- Grants.gateway(client.id, resource_owner["principal_uid"], params["scope"]),
             {:ok, code} <- Grants.authorize(params, resource_owner) do
          authorization_redirect(conn, params, code)
        else
          {:error, reason} ->
            redirect_authorization_error(conn, params, "access_denied", message(reason))
        end

      {true, :error} ->
        if LoginPolicy.silent?(params) do
          redirect_authorization_error(conn, params, "login_required", "Human login is required")
        else
          with {:ok, _providers} <- LoginPolicy.providers(client, params),
               {:ok, conn, transaction} <-
                 WebSession.begin_login(
                   conn,
                   :oauth,
                   params,
                   reauthentication_target(conn, client, params)
                 ) do
            redirect(conn, to: "/sessions/new?oauth=1&flow=" <> transaction.id)
          else
            {:error, reason} ->
              redirect_authorization_error(conn, params, "access_denied", message(reason))
          end
        end
    end
  end

  defp reauthentication_target(conn, client, params) do
    with true <- LoginPolicy.requires_login?(params),
         false <- LoginPolicy.select_account?(params),
         %{} = auth <- WebSession.oauth_session(conn),
         :ok <- LoginPolicy.authorize_source(client, auth["provider_id"]) do
      [expected_authentication_id: auth["authentication_id"]]
    else
      _ -> []
    end
  end

  defp current_resource_owner(conn, client, params) do
    with %{} = authentication <- WebSession.oauth_session(conn),
         true <- LoginPolicy.can_reuse?(authentication, params),
         :ok <- LoginPolicy.authorize_source(client, authentication["provider_id"]),
         :ok <-
           Ankole.Principals.HumanAccess.check(
             authentication["principal_uid"],
             authentication["access_version"]
           ) do
      {:ok, authentication, conn}
    else
      _ -> :error
    end
  end

  defp authorization_reference(conn, flow) do
    case WebSession.login_transaction(conn, flow) do
      {:ok, transaction} -> WebSession.transaction_reference(conn, transaction)
      _ -> nil
    end
  end

  defp redirect_authorization_error(conn, params, code, description) do
    query =
      %{
        "error" => code,
        "error_description" => description,
        "state" => if(is_binary(params["state"]), do: params["state"])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.sort()
      |> URI.encode_query()

    redirect(conn, external: append_query(params["redirect_uri"], query))
  end

  defp authorize_request_origin(conn, client_id) do
    case get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        if OIDC.origin_allowed?(client_id, origin), do: :ok, else: {:error, :origin_not_allowed}

      _multiple ->
        {:error, :origin_not_allowed}
    end
  end

  defp append_query(uri, query) do
    parsed = URI.parse(uri)
    existing = if parsed.query in [nil, ""], do: query, else: parsed.query <> "&" <> query
    URI.to_string(%{parsed | query: existing})
  end

  defp no_store(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
  end

  defp oauth_json_error(conn, status, code, description) do
    conn
    |> no_store()
    |> put_status(status)
    |> json(%{error: code, error_description: description})
  end

  defp token_json_error(conn, _status, "invalid_client", description) do
    case get_req_header(conn, "authorization") do
      [] ->
        oauth_json_error(conn, 400, "invalid_client", description)

      _headers ->
        # Other schemes need their own challenge protocol; do not reflect request schemes.
        conn
        |> put_resp_header("www-authenticate", "Basic realm=\"OIDC token\"")
        |> oauth_json_error(401, "invalid_client", description)
    end
  end

  defp token_json_error(conn, status, code, description),
    do: oauth_json_error(conn, status, code, description)

  defp message(value) when is_binary(value), do: value
  defp message(value), do: inspect(value)
end
