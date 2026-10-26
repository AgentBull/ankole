defmodule Ankole.OIDC.ClientAuthentication do
  @moduledoc false
  alias Ankole.{OIDC, Repo}
  alias Ankole.OIDC.Client

  def authenticate(conn, params, confidential_only? \\ false) do
    with {:ok, source, id, secret} <- credentials(conn, params),
         {:ok, client} <- put_client_tenant(id),
         :ok <- shape(client, source, params),
         :ok <- verify(client, secret),
         true <- not confidential_only? or client.client_type == :confidential do
      {:ok, client}
    else
      {:error, code, description} -> {:error, code, description}
      _ -> {:error, "invalid_client", "Client authentication failed"}
    end
  end

  def put_client_tenant(id) do
    with {:ok, client} <- Repo.across_tenants(fn -> OIDC.get_active_client(id) end) do
      Repo.put_tenant_id(client.tenant_id)
      {:ok, client}
    end
  end

  defp credentials(conn, params) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [] ->
        case params["client_id"] do
          id when is_binary(id) and id != "" -> {:ok, :public, id, nil}
          _ -> {:error, "invalid_client", "client_id is required"}
        end

      [_] ->
        case Plug.BasicAuth.parse_basic_auth(conn) do
          {id, secret} -> {:ok, :basic, URI.decode_www_form(id), URI.decode_www_form(secret)}
          _ -> {:error, "invalid_client", "client_secret_basic credentials are invalid"}
        end

      _ ->
        {:error, "invalid_client", "exactly one Authorization header is required"}
    end
  rescue
    ArgumentError -> {:error, "invalid_client", "client_secret_basic credentials are invalid"}
  end

  defp shape(%Client{client_type: :public}, :public, params) do
    if forbidden?(params),
      do: {:error, "invalid_client", "public Client must use client_id only"},
      else: :ok
  end

  defp shape(%Client{client_type: :confidential}, :basic, params) do
    if Map.has_key?(params, "client_id") or forbidden?(params),
      do: {:error, "invalid_request", "confidential Client must use client_secret_basic only"},
      else: :ok
  end

  defp shape(_, _, _), do: {:error, "invalid_client", "Client authentication method is invalid"}

  defp forbidden?(params),
    do:
      Enum.any?(
        ~w(client_secret client_assertion client_assertion_type),
        &Map.has_key?(params, &1)
      )

  defp verify(%Client{client_type: :public}, nil), do: :ok

  defp verify(client, supplied) do
    with {:ok, expected} when is_binary(expected) <- OIDC.client_secret(client),
         true <- Plug.Crypto.secure_compare(expected, supplied) do
      :ok
    else
      _ -> {:error, "invalid_client", "Client authentication failed"}
    end
  end
end
