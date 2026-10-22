defmodule Ankole.OIDC.UserInfo do
  @moduledoc false
  alias Ankole.{OIDC, Repo}
  alias Ankole.OIDC.{Claims, Tokens}

  def fetch(conn, params) do
    with {:ok, token} <- bearer(conn, params),
         {:ok, %{claims: claims, client: client}} <-
           Tokens.verify_access_context(token, Tokens.userinfo_audience()),
         :ok <- origin(conn, client) do
      Repo.put_tenant_id(client.tenant_id)

      with {:ok, principal, human} <- Claims.load(claims["sub"]),
           do:
             {:ok,
              Map.put(Claims.project(principal, human, claims["scope"]), "sub", principal.uid)}
    end
  end

  defp bearer(conn, params) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [] when conn.method == "POST" ->
        token(params["access_token"])

      [header] ->
        case String.split(header, " ", parts: 2, trim: true) do
          [scheme, raw] ->
            if String.downcase(scheme) == "bearer", do: token(raw), else: {:error, :invalid_token}

          _ ->
            {:error, :invalid_token}
        end

      _ ->
        {:error, :invalid_token}
    end
  end

  defp token(value) when is_binary(value) and value != "", do: {:ok, value}
  defp token(_), do: {:error, :invalid_token}

  defp origin(conn, client) do
    case Plug.Conn.get_req_header(conn, "origin") do
      [] ->
        :ok

      [origin] ->
        if OIDC.origin_allowed?(client, origin), do: :ok, else: {:error, :origin_not_allowed}

      _ ->
        {:error, :origin_not_allowed}
    end
  end
end
