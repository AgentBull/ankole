defmodule AnkoleWeb.Plugs.RequireConsoleAccessToken do
  @moduledoc """
  Authenticates console REST API requests with a Bearer access token.
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
