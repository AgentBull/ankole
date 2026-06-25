defmodule AnkoleWeb.Plugs.RequireConsoleAccessToken do
  @moduledoc """
  Authenticates console REST API requests with a Bearer access token.

  This is the gate for the stateless `console_api` pipeline. It does the work that
  session+CSRF do for the browser surfaces, but per-request and cookie-free: prove
  a valid console JWT, then re-confirm the principal is still an active admin.
  On success it stashes the principal/claims as assigns for downstream policy
  checks; any failure halts with a 401.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Ankole.AdminAuth
  alias AnkoleWeb.ConsoleTokens

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Three independent checks, all required: a well-formed bearer header, a JWT
    # that verifies as a console access token, and a subject that is an active
    # human admin *right now* — so a revoked admin's still-valid token is refused.
    with {:ok, token} <- bearer_token(conn),
         {:ok, %{"sub" => principal_uid} = claims} <- ConsoleTokens.verify_access_token(token),
         true <- AdminAuth.active_human_admin?(principal_uid) do
      conn
      |> assign(:current_principal_uid, principal_uid)
      |> assign(:console_token_claims, claims)
    else
      false ->
        unauthorized(conn, "invalid_token", "active admin access required")

      {:error, :missing_authorization} ->
        unauthorized(conn, "invalid_token", "bearer token required")

      {:error, _reason} ->
        unauthorized(conn, "invalid_token", "bearer token is invalid")
    end
  end

  # Accept only the exact `Bearer <token>` form with a non-empty token; anything
  # else is treated as no credential at all.
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
