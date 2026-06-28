defmodule AnkoleWeb.Plugs.RequireAIGatewayAccessToken do
  @moduledoc """
  Authenticates AIGateway runtime API requests with an agent or admin bearer token.
  """

  import Phoenix.Controller
  import Plug.Conn

  alias Ankole.AdminAuth
  alias Ankole.Principals
  alias AnkoleWeb.AIGatewayTokens
  alias AnkoleWeb.ConsoleTokens

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn) do
      case verify_agent_token(conn, token) do
        {:ok, conn} -> conn
        {:error, _reason} -> verify_admin_token(conn, token)
      end
    else
      {:error, :missing_authorization} ->
        unauthorized(conn, "invalid_token", "agent or admin bearer token required")
    end
  end

  defp verify_agent_token(conn, token) do
    with {:ok, %{"sub" => agent_uid} = claims} <- AIGatewayTokens.verify_api_key(token),
         {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         :active <- principal.status do
      {:ok,
       conn
       |> assign(:current_agent_uid, principal.uid)
       |> assign(:current_ai_gateway_subject_uid, principal.uid)
       |> assign(:current_ai_gateway_subject_type, "agent")
       |> assign(:ai_gateway_token_claims, claims)}
    else
      {:ok, %{principal: principal}} when principal.status != :active ->
        {:error, :inactive_agent}

      {:error, _reason} ->
        {:error, :invalid_agent_token}

      _other ->
        {:error, :invalid_agent_token}
    end
  end

  defp verify_admin_token(conn, token) do
    with {:ok, %{"sub" => principal_uid} = claims} <- ConsoleTokens.verify_access_token(token),
         true <- AdminAuth.active_human_admin?(principal_uid) do
      conn
      |> assign(:current_principal_uid, principal_uid)
      |> assign(:current_ai_gateway_subject_uid, principal_uid)
      |> assign(:current_ai_gateway_subject_type, "admin_human")
      |> assign(:console_token_claims, claims)
    else
      false ->
        unauthorized(conn, "invalid_token", "active admin access required")

      {:error, _reason} ->
        unauthorized(conn, "invalid_token", "bearer token is invalid")
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" -> {:ok, token}
      _headers -> {:error, :missing_authorization}
    end
  end

  defp unauthorized(conn, code, message) do
    conn
    |> put_status(401)
    |> json(%{error: %{code: code, message: message}})
    |> halt()
  end
end
