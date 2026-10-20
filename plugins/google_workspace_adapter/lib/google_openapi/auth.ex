defmodule GoogleOpenAPI.Auth do
  @moduledoc """
  Google OAuth 2.0 / OpenID Connect helpers.

  Covers the authorization-code login flow, the userinfo endpoint, and
  service-account JWT bearer grants for domain-wide delegation. This module
  builds the grant claims but never touches key material: the client's
  `assertion_signer` closure signs them. Bearer tokens are cached in ETS per
  `{service_account_email, subject, scope}` and refreshed shortly before
  expiry; concurrent fills are harmless last-write-wins.
  """

  alias GoogleOpenAPI.Cache
  alias GoogleOpenAPI.Client
  alias GoogleOpenAPI.Error

  @refresh_margin_seconds 60
  @assertion_lifetime_seconds 3600
  @jwt_bearer_grant_type "urn:ietf:params:oauth:grant-type:jwt-bearer"

  @spec authorize_url(keyword()) :: String.t()
  def authorize_url(opts) do
    auth_base_url =
      opts |> Keyword.get(:auth_base_url, "https://accounts.google.com") |> trim_url()

    params =
      %{
        client_id: Keyword.fetch!(opts, :client_id),
        response_type: "code",
        redirect_uri: Keyword.fetch!(opts, :redirect_uri),
        state: Keyword.fetch!(opts, :state),
        scope: Enum.join(Keyword.get(opts, :scopes, ["openid", "email", "profile"]), " ")
      }
      |> maybe_put(:hd, Keyword.get(opts, :hd))

    "#{auth_base_url}/o/oauth2/v2/auth?#{URI.encode_query(params)}"
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
           GoogleOpenAPI.request(:post, token_url(client),
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

  @doc """
  Fetches OpenID Connect userinfo claims for a delegated access token.
  """
  @spec userinfo(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def userinfo(%Client{} = client, access_token) when is_binary(access_token) do
    GoogleOpenAPI.request(:get, client.userinfo_base_url <> "/v1/userinfo",
      headers: GoogleOpenAPI.bearer_headers(access_token),
      req_options: client.req_options
    )
  end

  @doc """
  Returns a cached service-account bearer token for the given scope.

  The scope may be a string or a list of scopes. The delegated subject
  defaults to `client.delegated_subject`.
  """
  @spec jwt_bearer_token(Client.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def jwt_bearer_token(%Client{} = client, opts) do
    scope = opts |> Keyword.fetch!(:scope) |> normalize_scope()
    subject = Keyword.get(opts, :subject) || client.delegated_subject
    cache_key = {client.token_base_url, client.service_account_email, subject, scope}

    case cached_token(cache_key) do
      {:ok, token} -> {:ok, token}
      :miss -> fetch_jwt_bearer_token(client, subject, scope, cache_key)
    end
  end

  defp fetch_jwt_bearer_token(%Client{assertion_signer: nil}, _subject, _scope, _cache_key) do
    {:error, %Error{reason: :missing_assertion_signer}}
  end

  defp fetch_jwt_bearer_token(client, subject, scope, cache_key) do
    now = System.system_time(:second)

    claims =
      %{
        "iss" => client.service_account_email,
        "scope" => scope,
        "aud" => token_url(client),
        "iat" => now,
        "exp" => now + @assertion_lifetime_seconds
      }
      |> maybe_put("sub", subject)

    with {:ok, assertion} <- sign_assertion(client, claims),
         {:ok, body} <-
           GoogleOpenAPI.request(:post, token_url(client),
             form: [grant_type: @jwt_bearer_grant_type, assertion: assertion],
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

  defp sign_assertion(client, claims) do
    case client.assertion_signer.(claims) do
      {:ok, assertion} when is_binary(assertion) -> {:ok, assertion}
      {:error, reason} -> {:error, %Error{reason: :assertion_signing_failed, raw: reason}}
      other -> {:error, %Error{reason: :assertion_signing_failed, raw: other}}
    end
  end

  defp normalize_scope(scope) when is_binary(scope), do: scope
  defp normalize_scope(scopes) when is_list(scopes), do: Enum.join(scopes, " ")

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

  defp token_url(%Client{token_base_url: token_base_url}), do: token_base_url <> "/token"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp trim_url(url), do: String.trim_trailing(url, "/")
end
