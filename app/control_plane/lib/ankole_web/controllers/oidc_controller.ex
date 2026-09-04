defmodule AnkoleWeb.OIDCController do
  @moduledoc """
  Serves Ankole's OAuth 2.0 and OpenID Connect protocol endpoints.

  The token endpoint has two explicit authentication shapes. Console grants use
  the current administrator session and CSRF token. OIDC grants use only Client
  credentials from the request and never consult the browser session.
  """

  use AnkoleWeb, :controller

  @behaviour Boruta.Oauth.AuthorizeApplication
  @behaviour Boruta.Oauth.TokenApplication
  @behaviour Boruta.Openid.UserinfoApplication

  alias Ankole.AdminAuth
  alias Ankole.OIDC
  alias Ankole.OIDC.Boruta.ResourceOwners
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.SigningKey
  alias Ankole.OIDC.Tokens
  alias Ankole.TokenSigning
  alias AnkoleWeb.ConsoleTokens
  alias AnkoleWeb.Session, as: WebSession
  alias Boruta.Oauth.AuthorizeResponse
  alias Boruta.Oauth.Error, as: OAuthError
  alias Boruta.Openid.UserinfoResponse

  @browser_session_grant "urn:ankole:params:oauth:grant-type:browser-session"
  @supported_scopes Client.supported_scopes()
  @pkce_challenge ~r/\A[A-Za-z0-9_-]{43}\z/
  @pkce_verifier ~r/\A[A-Za-z0-9._~-]{43,128}\z/

  def discovery(conn, _params) do
    issuer = TokenSigning.issuer()

    json(conn, %{
      issuer: issuer,
      authorization_endpoint: issuer <> "/oauth/authorize",
      token_endpoint: issuer <> "/oauth/token",
      userinfo_endpoint: issuer <> "/oauth/userinfo",
      jwks_uri: issuer <> "/.well-known/jwks.json",
      response_types_supported: ["code"],
      response_modes_supported: ["query"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      subject_types_supported: ["public"],
      id_token_signing_alg_values_supported: ["RS256"],
      token_endpoint_auth_methods_supported: ["none", "client_secret_basic"],
      scopes_supported: @supported_scopes,
      claims_supported: ["sub", "name", "preferred_username", "picture", "email"],
      code_challenge_methods_supported: ["S256"]
    })
  end

  def jwks(conn, _params) do
    case SigningKey.public_jwk() do
      {:ok, jwk} -> json(conn, %{keys: [jwk]})
      {:error, _reason} -> oauth_json_error(conn, 500, "server_error", "signing key unavailable")
    end
  end

  def authorize(conn, params) do
    with {:ok, client, scope} <- validate_authorization_request(params) do
      continue_authorization(conn, params, client, scope)
    else
      {:error, code, description} ->
        authorization_request_error(conn, params, code, description)
    end
  end

  def resume_authorize(conn, _params) do
    case WebSession.oauth_authorization(conn) do
      params when is_map(params) -> authorize(%{conn | query_params: params}, params)
      _missing -> oauth_json_error(conn, 400, "invalid_request", "authorization request expired")
    end
  end

  def token(conn, params) do
    case token_request_kind(conn, params) do
      :console_browser_session -> console_browser_session_token(conn)
      :console_refresh -> console_refresh_token(conn, params)
      {:oidc, client} -> oidc_token(conn, client)
      {:error, code, description} -> oauth_json_error(conn, 400, code, description)
    end
  end

  def userinfo(conn, _params) do
    with {:ok, raw_token} <- bearer_token(conn),
         {:ok, claims} <- Tokens.verify_access(raw_token, Tokens.userinfo_audience()),
         :ok <- authorize_request_origin(conn, claims["client_id"]) do
      Boruta.Openid.userinfo(conn, __MODULE__)
    else
      {:error, :origin_not_allowed} ->
        oauth_json_error(conn, 403, "invalid_request", "Origin is not registered for this Client")

      {:error, _reason} ->
        oauth_json_error(conn, 401, "invalid_token", "access token is invalid")
    end
  end

  def options(conn, _params), do: send_resp(conn, 204, "")

  @impl true
  def authorize_success(conn, response) do
    conn
    |> WebSession.clear_oauth_authorization()
    |> redirect(external: AuthorizeResponse.redirect_to_url(response))
  end

  @impl true
  def authorize_error(conn, %OAuthError{} = error), do: render_authorize_error(conn, error)

  @impl true
  def preauthorize_success(conn, _authorization), do: conn

  @impl true
  def preauthorize_error(conn, %OAuthError{} = error), do: render_authorize_error(conn, error)

  @impl true
  def token_success(conn, response) do
    payload = %{
      access_token: response.access_token,
      token_type: response.token_type,
      expires_in: response.expires_in,
      scope: response.token.scope
    }

    payload = maybe_put(payload, :refresh_token, response.refresh_token)
    payload = maybe_put(payload, :id_token, response.id_token)

    conn
    |> no_store()
    |> json(payload)
  end

  @impl true
  def token_error(conn, %OAuthError{} = error) do
    oauth_json_error(
      conn,
      Plug.Conn.Status.code(error.status),
      Atom.to_string(error.error),
      error.error_description
    )
  end

  @impl true
  def userinfo_fetched(conn, response) do
    conn
    |> put_resp_content_type(UserinfoResponse.content_type(response))
    |> send_resp(200, encode_userinfo(UserinfoResponse.payload(response)))
  end

  @impl true
  def unauthorized(conn, %OAuthError{} = error) do
    oauth_json_error(conn, 401, Atom.to_string(error.error), error.error_description)
  end

  defp continue_authorization(conn, params, client, scope) do
    params = Map.put(params, "scope", scope)

    case current_resource_owner(conn) do
      {:ok, resource_owner, conn} ->
        with :ok <- authorize_gateway_scope(client, resource_owner.sub, scope) do
          Boruta.Oauth.authorize(%{conn | query_params: params}, resource_owner, __MODULE__)
        else
          {:error, reason} ->
            redirect_authorization_error(conn, params, "access_denied", message(reason))
        end

      :error ->
        if params["prompt"] == "none" do
          redirect_authorization_error(conn, params, "login_required", "Human login is required")
        else
          conn
          |> WebSession.put_oauth_authorization(params)
          |> redirect(to: "/sessions/new?oauth=1")
        end
    end
  end

  defp current_resource_owner(conn) do
    case WebSession.oauth_session(conn) do
      %{"principal_uid" => principal_uid} ->
        case ResourceOwners.load(principal_uid) do
          {:ok, resource_owner} -> {:ok, resource_owner, conn}
          {:error, _reason} -> current_admin_resource_owner(conn)
        end

      _missing ->
        current_admin_resource_owner(conn)
    end
  end

  defp current_admin_resource_owner(conn) do
    case WebSession.admin_session(conn) do
      %{"principal_uid" => principal_uid} = session ->
        with true <- AdminAuth.active_human_admin?(principal_uid),
             {:ok, resource_owner} <- ResourceOwners.load(principal_uid) do
          conn =
            WebSession.put_oauth_session(conn, %{
              principal_uid: principal_uid,
              provider_id: session["provider_id"],
              external_id: session["external_id"]
            })

          {:ok, resource_owner, conn}
        else
          _inactive -> :error
        end

      _missing ->
        :error
    end
  end

  defp validate_authorization_request(params) do
    with "code" <- params["response_type"],
         true <- params["response_mode"] in [nil, "query"],
         false <- Map.has_key?(params, "request"),
         false <- Map.has_key?(params, "request_uri"),
         client_id when is_binary(client_id) <- params["client_id"],
         {:ok, client} <- OIDC.get_active_client(client_id),
         redirect_uri when is_binary(redirect_uri) <- params["redirect_uri"],
         true <- redirect_uri in client.redirect_uris,
         scope when is_binary(scope) <- params["scope"],
         {:ok, scope} <- validate_scope(scope, client),
         "S256" <- params["code_challenge_method"],
         challenge when is_binary(challenge) <- params["code_challenge"],
         true <- Regex.match?(@pkce_challenge, challenge),
         true <- optional_string?(params["state"]),
         true <- optional_string?(params["nonce"]),
         true <- params["prompt"] in [nil, "none"] do
      {:ok, client, scope}
    else
      {:error, :not_found} -> {:error, "invalid_client", "Client is unknown or disabled"}
      {:error, code, description} -> {:error, code, description}
      false -> {:error, "invalid_request", "authorization request is not supported"}
      _invalid -> {:error, "invalid_request", "authorization request is not valid"}
    end
  end

  defp validate_scope(scope, client) do
    scopes = String.split(scope, " ", trim: true)

    cond do
      scopes == [] ->
        {:error, "invalid_scope", "scope is required"}

      length(scopes) != length(Enum.uniq(scopes)) ->
        {:error, "invalid_scope", "scope contains duplicates"}

      "openid" not in scopes ->
        {:error, "invalid_scope", "openid scope is required"}

      not MapSet.subset?(MapSet.new(scopes), MapSet.new(client.scopes)) ->
        {:error, "invalid_scope", "Client is not allowed to request this scope"}

      true ->
        {:ok, Enum.join(scopes, " ")}
    end
  end

  defp authorize_gateway_scope(client, principal_uid, scope) do
    if "ai_gateway.write" in String.split(scope, " ", trim: true) do
      case OIDC.authorize_ai_gateway(client.id, principal_uid) do
        {:ok, _client} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp authorization_request_error(conn, params, code, description) do
    case validated_redirect_uri(params) do
      {:ok, _client} -> redirect_authorization_error(conn, params, code, description)
      :error -> oauth_json_error(conn, 400, code, description)
    end
  end

  defp validated_redirect_uri(%{"client_id" => client_id, "redirect_uri" => redirect_uri}) do
    with {:ok, client} <- OIDC.get_active_client(client_id),
         true <- redirect_uri in client.redirect_uris do
      {:ok, client}
    else
      _invalid -> :error
    end
  end

  defp validated_redirect_uri(_params), do: :error

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

  defp render_authorize_error(conn, %OAuthError{redirect_uri: uri} = error)
       when is_binary(uri) and uri != "" do
    redirect(conn, external: OAuthError.redirect_to_url(error))
  end

  defp render_authorize_error(conn, %OAuthError{} = error) do
    oauth_json_error(
      conn,
      Plug.Conn.Status.code(error.status),
      Atom.to_string(error.error),
      error.error_description
    )
  end

  defp token_request_kind(conn, %{"grant_type" => @browser_session_grant} = params) do
    if oidc_credential_shape?(conn, params),
      do: {:error, "invalid_request", "Console grant rejects OIDC Client credentials"},
      else: :console_browser_session
  end

  defp token_request_kind(conn, %{"grant_type" => "refresh_token"} = params) do
    if oidc_credential_shape?(conn, params) do
      oidc_client_shape(conn, params)
    else
      :console_refresh
    end
  end

  defp token_request_kind(conn, %{"grant_type" => "authorization_code"} = params) do
    if oidc_credential_shape?(conn, params) do
      oidc_client_shape(conn, params)
    else
      {:error, "invalid_client", "OIDC Client credentials are required"}
    end
  end

  defp token_request_kind(_conn, %{"grant_type" => _grant_type}),
    do: {:error, "unsupported_grant_type", "grant_type is not supported"}

  defp token_request_kind(_conn, _params),
    do: {:error, "invalid_request", "grant_type is required"}

  defp oidc_client_shape(conn, params) do
    with {:ok, source, client_id} <- request_client_credentials(conn, params),
         {:ok, client} <- OIDC.get_active_client(client_id),
         :ok <- client_authentication_shape(client, source, params),
         :ok <- validate_grant_request(params),
         :ok <- authorize_request_origin(conn, client.id) do
      {:oidc, client}
    else
      {:error, :origin_not_allowed} ->
        {:error, "invalid_request", "Origin is not registered for this Client"}

      {:error, :not_found} ->
        {:error, "invalid_client", "Client is unknown or disabled"}

      {:error, code, description} ->
        {:error, code, description}
    end
  end

  defp request_client_credentials(conn, params) do
    case get_req_header(conn, "authorization") do
      [] ->
        case params["client_id"] do
          client_id when is_binary(client_id) and client_id != "" -> {:ok, :public, client_id}
          _missing -> {:error, "invalid_client", "client_id is required"}
        end

      [header] ->
        case Boruta.BasicAuth.decode(header) do
          {:ok, [client_id, _secret]} when client_id != "" -> {:ok, :basic, client_id}
          _invalid -> {:error, "invalid_client", "client_secret_basic credentials are invalid"}
        end

      _multiple ->
        {:error, "invalid_client", "exactly one Authorization header is required"}
    end
  end

  defp client_authentication_shape(%Client{client_type: :public}, :public, params) do
    if forbidden_oidc_auth_param?(params),
      do: {:error, "invalid_client", "public Client must use client_id only"},
      else: :ok
  end

  defp client_authentication_shape(%Client{client_type: :confidential}, :basic, params) do
    if Map.has_key?(params, "client_id") or forbidden_oidc_auth_param?(params),
      do: {:error, "invalid_client", "confidential Client must use client_secret_basic only"},
      else: :ok
  end

  defp client_authentication_shape(%Client{client_type: :public}, _source, _params),
    do: {:error, "invalid_client", "public Client must use client_id only"}

  defp client_authentication_shape(%Client{client_type: :confidential}, _source, _params),
    do: {:error, "invalid_client", "confidential Client must use client_secret_basic"}

  defp forbidden_oidc_auth_param?(params) do
    Enum.any?(
      ["client_secret", "client_assertion", "client_assertion_type"],
      &Map.has_key?(params, &1)
    )
  end

  defp validate_grant_request(%{"grant_type" => "authorization_code"} = params) do
    case params["code_verifier"] do
      verifier when is_binary(verifier) ->
        if Regex.match?(@pkce_verifier, verifier),
          do: :ok,
          else: {:error, "invalid_request", "code_verifier is invalid"}

      _missing ->
        {:error, "invalid_request", "code_verifier is invalid"}
    end
  end

  defp validate_grant_request(_params), do: :ok

  defp oidc_credential_shape?(conn, params) do
    get_req_header(conn, "authorization") != [] or
      Enum.any?(
        ["client_id", "client_secret", "client_assertion", "client_assertion_type"],
        &Map.has_key?(params, &1)
      )
  end

  defp console_browser_session_token(conn) do
    with :ok <- require_console_browser_request(conn),
         {:ok, session} <- active_admin_session(conn),
         {:ok, token_set} <- ConsoleTokens.mint_for_session(session) do
      conn |> no_store() |> json(token_set)
    else
      {:error, :csrf} ->
        oauth_json_error(conn, 403, "invalid_request", "CSRF token is invalid")

      {:error, :origin} ->
        oauth_json_error(conn, 403, "invalid_request", "same Origin is required")

      :error ->
        oauth_json_error(conn, 401, "invalid_grant", "active administrator session required")

      {:error, reason} ->
        oauth_json_error(conn, 400, "server_error", message(reason))
    end
  end

  defp console_refresh_token(conn, params) do
    with refresh_token when is_binary(refresh_token) and refresh_token != "" <-
           params["refresh_token"],
         :ok <- require_console_browser_request(conn),
         {:ok, session} <- active_admin_session(conn),
         {:ok, token_set} <- ConsoleTokens.refresh_for_session(refresh_token, session) do
      conn |> no_store() |> json(token_set)
    else
      nil ->
        oauth_json_error(conn, 400, "invalid_request", "refresh_token is required")

      "" ->
        oauth_json_error(conn, 400, "invalid_request", "refresh_token is required")

      {:error, :csrf} ->
        oauth_json_error(conn, 403, "invalid_request", "CSRF token is invalid")

      {:error, :origin} ->
        oauth_json_error(conn, 403, "invalid_request", "same Origin is required")

      :error ->
        oauth_json_error(conn, 401, "invalid_grant", "active administrator session required")

      {:error, reason} ->
        oauth_json_error(conn, 400, "invalid_grant", message(reason))
    end
  end

  defp oidc_token(conn, _client), do: Boruta.Oauth.token(conn, __MODULE__)

  defp require_console_browser_request(conn) do
    with :ok <- require_same_origin(conn),
         :ok <- require_csrf(conn) do
      :ok
    end
  end

  defp require_same_origin(conn) do
    case get_req_header(conn, "origin") do
      [origin] -> if origin == request_origin(conn), do: :ok, else: {:error, :origin}
      _missing_or_multiple -> {:error, :origin}
    end
  end

  defp require_csrf(conn) do
    state = get_session(conn, "_csrf_token")
    token = List.first(get_req_header(conn, "x-csrf-token")) || conn.body_params["_csrf_token"]

    if Plug.CSRFProtection.valid_state_and_csrf_token?(state, token),
      do: :ok,
      else: {:error, :csrf}
  end

  defp active_admin_session(conn) do
    case WebSession.admin_session(conn) do
      %{"principal_uid" => principal_uid} = session ->
        if AdminAuth.active_human_admin?(principal_uid), do: {:ok, session}, else: :error

      _missing ->
        :error
    end
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

  defp bearer_token(conn) do
    case Boruta.Oauth.BearerToken.extract_token(conn) do
      {:ok, token} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_query(uri, query) do
    parsed = URI.parse(uri)
    existing = if parsed.query in [nil, ""], do: query, else: parsed.query <> "&" <> query
    URI.to_string(%{parsed | query: existing})
  end

  defp request_origin(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
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

  defp encode_userinfo(payload) when is_map(payload), do: Ankole.JSON.encode!(payload)
  defp encode_userinfo(payload) when is_binary(payload), do: payload

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value)

  defp message(value) when is_binary(value), do: value
  defp message(value), do: inspect(value)
end
