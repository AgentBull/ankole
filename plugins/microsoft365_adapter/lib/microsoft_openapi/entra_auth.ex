defmodule MicrosoftOpenAPI.EntraAuth do
  @moduledoc """
  Microsoft Entra ID v2.0 OAuth helpers.

  Covers the authorization-code login flow and client-credentials tokens.
  Client-credentials tokens are cached in ETS per
  `{login_base_url, tenant, client_id, scope}` and refreshed shortly before
  expiry; concurrent fills are harmless last-write-wins.
  """

  alias MicrosoftOpenAPI.Cache
  alias MicrosoftOpenAPI.Client
  alias MicrosoftOpenAPI.Error

  @refresh_margin_seconds 60

  @spec authorize_url(keyword()) :: String.t()
  def authorize_url(opts) do
    login_base_url =
      opts |> Keyword.get(:login_base_url, "https://login.microsoftonline.com") |> trim_url()

    tenant = Keyword.fetch!(opts, :tenant)

    params =
      %{
        client_id: Keyword.fetch!(opts, :client_id),
        response_type: "code",
        response_mode: "query",
        redirect_uri: Keyword.fetch!(opts, :redirect_uri),
        state: Keyword.fetch!(opts, :state),
        scope: Enum.join(Keyword.get(opts, :scopes, ["openid", "profile", "email"]), " ")
      }

    "#{login_base_url}/#{URI.encode(tenant)}/oauth2/v2.0/authorize?#{URI.encode_query(params)}"
  end

  @spec exchange_code(Client.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def exchange_code(%Client{} = client, opts) do
    form = [
      client_id: client.client_id,
      client_secret: Client.client_secret(client),
      grant_type: "authorization_code",
      code: Keyword.fetch!(opts, :code),
      redirect_uri: Keyword.fetch!(opts, :redirect_uri)
    ]

    with {:ok, body} <-
           MicrosoftOpenAPI.request(:post, token_url(client, client.tenant_id),
             form: form,
             req_options: client.req_options
           ) do
      {:ok,
       %{
         access_token: Map.get(body, "access_token"),
         id_token: Map.get(body, "id_token"),
         expires_in: Map.get(body, "expires_in"),
         raw: body
       }}
    end
  end

  @spec client_credentials_token(Client.t(), keyword()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def client_credentials_token(%Client{} = client, opts) do
    scope = Keyword.fetch!(opts, :scope)
    tenant = Keyword.get(opts, :tenant) || client.tenant_id
    cache_key = {client.login_base_url, tenant, client.client_id, scope}

    case cached_token(cache_key) do
      {:ok, token} -> {:ok, token}
      :miss -> fetch_client_credentials_token(client, tenant, scope, cache_key)
    end
  end

  defp fetch_client_credentials_token(client, tenant, scope, cache_key) do
    form = [
      client_id: client.client_id,
      client_secret: Client.client_secret(client),
      grant_type: "client_credentials",
      scope: scope
    ]

    with {:ok, body} <-
           MicrosoftOpenAPI.request(:post, token_url(client, tenant),
             form: form,
             req_options: client.req_options
           ),
         {:ok, token, expires_in} <- token_from_body(body) do
      expires_at =
        System.monotonic_time(:millisecond) +
          :timer.seconds(max(expires_in - @refresh_margin_seconds, 1))

      :ets.insert(Cache.token_table(), {cache_key, token, expires_at})
      {:ok, token}
    end
  end

  defp token_from_body(%{"access_token" => token} = body) when is_binary(token) do
    case Map.get(body, "expires_in") do
      seconds when is_integer(seconds) and seconds > 0 -> {:ok, token, seconds}
      _missing -> {:ok, token, 300}
    end
  end

  defp token_from_body(body),
    do: {:error, %Error{reason: :unexpected_shape, raw: body}}

  defp cached_token(cache_key) do
    case :ets.lookup(Cache.token_table(), cache_key) do
      [{^cache_key, token, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, token}, else: :miss

      [] ->
        :miss
    end
  end

  defp token_url(client, tenant) when is_binary(tenant),
    do: "#{client.login_base_url}/#{URI.encode(tenant)}/oauth2/v2.0/token"

  defp trim_url(url), do: String.trim_trailing(url, "/")
end
