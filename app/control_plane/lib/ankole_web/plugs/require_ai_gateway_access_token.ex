defmodule AnkoleWeb.Plugs.RequireAIGatewayAccessToken do
  @moduledoc """
  Authenticates AIGateway requests as an Agent, Console administrator, or OIDC Human.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Ankole.AdminAuth
  alias Ankole.AIGateway.Tokens, as: AgentTokens
  alias Ankole.OIDC
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.Grant
  alias Ankole.Principals
  alias Ankole.TokenSigning
  alias AnkoleWeb.ConsoleTokens

  @behaviour Plug

  @application_protocol "ankole.responses.v1"
  @audience "ankole.ai_gateway"
  @credential_prefix "base64url.bearer.phx."
  @token_type "at+jwt"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token, source} <- bearer_token(conn) do
      case TokenSigning.verify(token, @audience, @token_type) do
        {:ok, claims} -> authenticate_claims(conn, token, source, claims)
        {:error, _reason} -> unauthorized(conn, "invalid_token", "bearer token is invalid")
      end
    else
      {:error, :ambiguous_authorization} ->
        unauthorized(conn, "invalid_token", "use one bearer credential transport")

      {:error, _reason} ->
        unauthorized(conn, "invalid_token", "Agent, Console, or OIDC Human bearer token required")
    end
  end

  defp authenticate_claims(conn, _token, source, %{"subject_type" => "agent"} = claims),
    do: authenticate_agent_claims(conn, claims, source)

  defp authenticate_claims(
         conn,
         token,
         source,
         %{"subject_type" => "human", "client_id" => client_id} = claims
       )
       when is_binary(client_id),
       do: authenticate_oidc_claims(conn, token, claims, source)

  defp authenticate_claims(conn, _token, source, %{"subject_type" => "human"} = claims),
    do: authenticate_admin_claims(conn, claims, source)

  defp authenticate_claims(conn, _token, _source, _claims),
    do: unauthorized(conn, "invalid_token", "bearer token is invalid")

  defp authenticate_agent_claims(conn, claims, source) do
    with {:ok, %{"sub" => agent_uid} = claims} <- AgentTokens.validate_api_key_claims(claims),
         {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         :active <- principal.status,
         :ok <- authorize_non_client_origin(conn, source) do
      conn
      |> assign(:current_agent_uid, principal.uid)
      |> assign(:current_ai_gateway_subject_uid, principal.uid)
      |> assign(:current_ai_gateway_subject_type, "agent")
      |> assign(:ai_gateway_token_claims, claims)
      |> maybe_assign_application_protocol(source)
    else
      _invalid -> unauthorized(conn, "invalid_token", "bearer token is invalid")
    end
  end

  defp authenticate_admin_claims(conn, claims, source) do
    with {:ok, %{"sub" => principal_uid} = claims} <- ConsoleTokens.validate_access_claims(claims),
         true <- AdminAuth.active_human_admin?(principal_uid),
         :ok <- authorize_non_client_origin(conn, source) do
      conn
      |> assign(:current_principal_uid, principal_uid)
      |> assign(:current_ai_gateway_subject_uid, principal_uid)
      |> assign(:current_ai_gateway_subject_type, "admin_human")
      |> assign(:console_token_claims, claims)
      |> maybe_assign_application_protocol(source)
    else
      _invalid -> unauthorized(conn, "invalid_token", "bearer token is invalid")
    end
  end

  defp authenticate_oidc_claims(conn, token, claims, source) do
    with {:ok, grant} <- Grant.authorize_claims(token, claims, conn.body_params["model"]),
         :ok <- authorize_client_origin(conn, source, grant.client) do
      conn
      |> assign(:current_principal_uid, grant.principal_uid)
      |> assign(:current_ai_gateway_subject_uid, grant.principal_uid)
      |> assign(:current_ai_gateway_subject_type, "oidc_human")
      |> assign(:oidc_grant, grant)
      |> maybe_assign_application_protocol(source)
    else
      {:error, :model_not_allowed} ->
        forbidden(conn, "model_not_allowed", "OIDC Client does not allow this model")

      {:error, reason}
      when reason in [
             :scope_revoked,
             :inactive_human,
             :group_not_allowed,
             :not_found,
             :origin_not_allowed,
             :origin_required
           ] ->
        forbidden(conn, "access_denied", "OIDC Client policy does not allow this request")

      _invalid ->
        unauthorized(conn, "invalid_token", "bearer token is invalid")
    end
  end

  defp bearer_token(conn) do
    authorization = authorization_token(conn)
    websocket = websocket_protocol_token(conn)

    case {authorization, websocket} do
      {{:ok, _token}, {:ok, _other}} -> {:error, :ambiguous_authorization}
      {{:ok, token}, :missing} -> {:ok, token, :authorization_header}
      {:missing, {:ok, token}} -> {:ok, token, :websocket_protocol}
      {{:error, reason}, _other} -> {:error, reason}
      {_other, {:error, reason}} -> {:error, reason}
      _missing -> {:error, :missing_authorization}
    end
  end

  defp authorization_token(conn) do
    case get_req_header(conn, "authorization") do
      [] -> :missing
      ["Bearer " <> token] when token != "" -> {:ok, token}
      [_invalid] -> {:error, :invalid_authorization_header}
      _multiple -> {:error, :invalid_authorization_header}
    end
  end

  defp websocket_protocol_token(conn) do
    protocols = websocket_protocols(conn)

    credentials = Enum.filter(protocols, &String.starts_with?(&1, @credential_prefix))

    cond do
      protocols == [] ->
        :missing

      credentials == [] ->
        :missing

      @application_protocol not in protocols or length(credentials) != 1 ->
        {:error, :invalid_websocket_protocol}

      true ->
        encoded = credentials |> hd() |> String.replace_prefix(@credential_prefix, "")

        case Base.url_decode64(encoded, padding: false) do
          {:ok, token} when token != "" -> {:ok, token}
          _invalid -> {:error, :invalid_websocket_protocol}
        end
    end
  end

  defp websocket_protocols(conn) do
    conn
    |> get_req_header("sec-websocket-protocol")
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
  end

  defp authorize_client_origin(conn, :websocket_protocol, %Client{} = client) do
    case request_origin_header(conn) do
      {:ok, origin} ->
        if OIDC.origin_allowed?(client, origin), do: :ok, else: {:error, :origin_not_allowed}

      :missing ->
        {:error, :origin_required}

      :invalid ->
        {:error, :origin_not_allowed}
    end
  end

  defp authorize_client_origin(conn, :authorization_header, %Client{} = client) do
    case request_origin_header(conn) do
      :missing ->
        :ok

      {:ok, origin} ->
        if OIDC.origin_allowed?(client, origin), do: :ok, else: {:error, :origin_not_allowed}

      :invalid ->
        {:error, :origin_not_allowed}
    end
  end

  defp authorize_non_client_origin(conn, :websocket_protocol) do
    if request_origin_header(conn) == {:ok, request_origin(conn)},
      do: :ok,
      else: {:error, :origin_not_allowed}
  end

  defp authorize_non_client_origin(conn, :authorization_header) do
    case request_origin_header(conn) do
      :missing ->
        :ok

      {:ok, origin} ->
        if origin == request_origin(conn), do: :ok, else: {:error, :origin_not_allowed}

      :invalid ->
        {:error, :origin_not_allowed}
    end
  end

  defp request_origin_header(conn) do
    case get_req_header(conn, "origin") do
      [] -> :missing
      [origin] -> {:ok, origin}
      _multiple -> :invalid
    end
  end

  defp request_origin(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end

  defp maybe_assign_application_protocol(conn, _source) do
    if @application_protocol in websocket_protocols(conn),
      do: assign(conn, :ai_gateway_websocket_protocol, @application_protocol),
      else: conn
  end

  defp unauthorized(conn, code, message) do
    conn
    |> put_status(401)
    |> json(%{error: %{code: code, message: message}})
    |> halt()
  end

  defp forbidden(conn, code, message) do
    conn
    |> put_status(403)
    |> json(%{error: %{code: code, message: message}})
    |> halt()
  end
end
