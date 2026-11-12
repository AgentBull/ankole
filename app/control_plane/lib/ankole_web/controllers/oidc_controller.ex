defmodule AnkoleWeb.OIDCController do
  @moduledoc """
  Serves Ankole's OAuth 2.0 and OpenID Connect protocol endpoints.

  The token endpoint uses the declared OIDC Client credentials. It does not
  use the browser session.
  """

  use AnkoleWeb, :controller

  alias Ankole.OIDC
  alias Ankole.OIDC.{AuthorizationRequests, ClientAuthentication, Grants, LoginPolicy}
  alias AnkoleWeb.Session, as: WebSession

  def discovery(conn, _params), do: json(conn, OIDC.discovery_metadata())

  def desktop_discovery(conn, params) do
    with {:ok, true} <- Ankole.Setup.Config.completed?(),
         {:ok, tenant} <- resolve_desktop_tenant(conn, params),
         {:ok, client} <- Ankole.Repo.with_tenant(tenant.id, &OIDC.ensure_desktop_client/0) do
      pod_origin = AnkoleWeb.PodURL.origin(conn, tenant)

      conn
      |> no_store()
      |> json(%{
        issuer: Ankole.OIDC.Config.issuer(),
        tenant_id: tenant.id,
        tenant_slug: tenant.slug,
        display_name: tenant.display_name || tenant.slug,
        avatar_url: tenant.avatar_url,
        pod_origin: pod_origin,
        site_origin: AnkoleWeb.PodURL.site_origin(conn),
        authorization_endpoint: pod_origin <> "/oauth/authorize",
        token_endpoint: pod_origin <> "/oauth/token",
        userinfo_endpoint: pod_origin <> "/oauth/userinfo",
        client_id: client.id,
        redirect_uri: OIDC.desktop_redirect_uri(),
        scopes_supported:
          Enum.filter(client.scopes, &(&1 in ~w(openid profile email offline_access pod)))
      })
    else
      {:ok, false} ->
        oauth_json_error(
          conn,
          503,
          "temporarily_unavailable",
          "installation setup is incomplete"
        )

      {:error, :desktop_client_disabled} ->
        oauth_json_error(
          conn,
          403,
          "desktop_client_disabled",
          "desktop sign-in is disabled for this Pod"
        )

      {:error, :tenant_suspended} ->
        oauth_json_error(conn, 403, "access_denied", "Pod is unavailable")

      _ ->
        oauth_json_error(conn, 404, "pod_not_found", "Pod workspace was not found")
    end
  end

  defp resolve_desktop_tenant(conn, params) do
    slug = if is_binary(params["slug"]), do: String.trim(params["slug"]), else: ""

    cond do
      match?({:pod, _}, conn.assigns[:host_context]) ->
        {:pod, tenant_id} = conn.assigns.host_context

        with {:ok, tenant} <- Ankole.Tenants.get(tenant_id),
             true <-
               Ankole.Tenants.accepting_work?(tenant) and (slug == "" or tenant.slug == slug),
             do: {:ok, tenant},
             else: (_ -> {:error, :not_found})

      slug != "" ->
        Ankole.Tenants.active_by_slug(slug)

      is_nil(Application.get_env(:ankole, :host_policy)) and
          is_nil(AnkoleWeb.Plugs.RequestHost.classifier()) ->
        with {:ok, tenant} <- Ankole.Tenants.privileged(),
             true <- Ankole.Tenants.accepting_work?(tenant),
             do: {:ok, tenant},
             else: (_ -> {:error, :not_found})

      true ->
        {:error, :not_found}
    end
  end

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

  def resume_authorize(conn, %{"oauth_request" => id}) do
    browser_ref = WebSession.browser_reference(conn)

    result =
      AuthorizationRequests.consume(
        browser_ref,
        id,
        authorization_reference(conn, browser_ref, id),
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
          "authorization request expired or not allowed"
        )
    end
  end

  def resume_authorize(conn, _params),
    do: oauth_json_error(conn, 400, "invalid_request", "authorization request is required")

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
               conn = WebSession.ensure_browser(conn),
               {:ok, request} <-
                 AuthorizationRequests.begin(
                   WebSession.browser_reference(conn),
                   client.id,
                   params,
                   reauthentication_target(conn, client, params)
                 ) do
            redirect(conn, to: "/sessions/new?oauth_request=" <> request.id)
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

  defp authorization_reference(conn, browser_ref, id) do
    case AuthorizationRequests.get(browser_ref, id) do
      {:ok, request} -> WebSession.authorization_reference(conn, request)
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
