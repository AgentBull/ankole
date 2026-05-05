defmodule FeishuOpenAPI.Auth do
  @moduledoc """
  Pre-baked auth endpoints. These are the only business endpoints the SDK
  speaks directly — everything else is reached via `FeishuOpenAPI.request/4`.

  All functions call through `FeishuOpenAPI.request/4` with
  `access_token_type: nil`, so they bypass `FeishuOpenAPI.TokenManager` and won't
  recurse when invoked by it.

  Normalizes the Feishu response shape `{"code": 0, "expire": e, "*_access_token": t}`
  into `{:ok, %{token: t, expire: e}}`.
  """

  alias FeishuOpenAPI.{Client, Error}

  @app_access_token_internal "/open-apis/auth/v3/app_access_token/internal"
  @app_access_token_marketplace "/open-apis/auth/v3/app_access_token"
  @tenant_access_token_internal "/open-apis/auth/v3/tenant_access_token/internal"
  @tenant_access_token_marketplace "/open-apis/auth/v3/tenant_access_token"
  @app_ticket_resend_path "/open-apis/auth/v3/app_ticket/resend"
  @oauth_token "/open-apis/authen/v2/oauth/token"

  @type token_resp :: %{token: String.t(), expire: integer()}
  @type user_token_resp :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          token_type: String.t() | nil,
          expires_in: integer() | nil,
          refresh_expires_in: integer() | nil,
          scope: String.t() | nil,
          raw: map()
        }

  @doc """
  Self-built apps: fetch a `tenant_access_token`.

      {:ok, %{token: "t-...", expire: 7200}} = FeishuOpenAPI.Auth.tenant_access_token(client)
  """
  @spec tenant_access_token(Client.t()) :: {:ok, token_resp()} | {:error, Error.t()}
  def tenant_access_token(%Client{} = client) do
    FeishuOpenAPI.post(client, @tenant_access_token_internal,
      body: %{app_id: client.app_id, app_secret: Client.app_secret(client)},
      access_token_type: nil
    )
    |> normalize(:tenant_access_token)
  end

  @doc """
  Self-built apps: fetch an `app_access_token`.
  """
  @spec app_access_token(Client.t()) :: {:ok, token_resp()} | {:error, Error.t()}
  def app_access_token(%Client{} = client) do
    FeishuOpenAPI.post(client, @app_access_token_internal,
      body: %{app_id: client.app_id, app_secret: Client.app_secret(client)},
      access_token_type: nil
    )
    |> normalize(:app_access_token)
  end

  @doc """
  Marketplace apps: fetch an `app_access_token` using an `app_ticket`.
  """
  @spec app_access_token_marketplace(Client.t(), String.t()) ::
          {:ok, token_resp()} | {:error, Error.t()}
  def app_access_token_marketplace(%Client{} = client, app_ticket) when is_binary(app_ticket) do
    FeishuOpenAPI.post(client, @app_access_token_marketplace,
      body: %{
        app_id: client.app_id,
        app_secret: Client.app_secret(client),
        app_ticket: app_ticket
      },
      access_token_type: nil
    )
    |> normalize(:app_access_token)
  end

  @doc """
  Marketplace apps: fetch a `tenant_access_token` using an `app_access_token`
  plus a `tenant_key`.
  """
  @spec tenant_access_token_marketplace(Client.t(), String.t(), String.t()) ::
          {:ok, token_resp()} | {:error, Error.t()}
  def tenant_access_token_marketplace(%Client{} = client, app_access_token, tenant_key)
      when is_binary(app_access_token) and is_binary(tenant_key) do
    FeishuOpenAPI.post(client, @tenant_access_token_marketplace,
      body: %{app_access_token: app_access_token, tenant_key: tenant_key},
      access_token_type: nil
    )
    |> normalize(:tenant_access_token)
  end

  @doc """
  Marketplace apps: ask Feishu to resend the `app_ticket` push.

  Typically used on application startup for marketplace apps that have lost
  their cached app_ticket.
  """
  @spec app_ticket_resend(Client.t()) :: {:ok, map()} | {:error, Error.t()}
  def app_ticket_resend(%Client{} = client) do
    FeishuOpenAPI.post(client, @app_ticket_resend_path,
      body: %{app_id: client.app_id, app_secret: Client.app_secret(client)},
      access_token_type: nil
    )
  end

  @doc """
  Exchange an OAuth authorization code for a `user_access_token`.

  Uses Feishu's standard OAuth token endpoint. Options:

    * `:redirect_uri` - the callback URL used to request the authorization code.
    * `:grant_type` - defaults to `"authorization_code"`.
  """
  @spec user_access_token(Client.t(), String.t(), keyword() | String.t()) ::
          {:ok, user_token_resp()} | {:error, Error.t()}
  def user_access_token(client, code, opts \\ [])

  def user_access_token(%Client{} = client, code, grant_type)
      when is_binary(code) and is_binary(grant_type) do
    user_access_token(client, code, grant_type: grant_type)
  end

  def user_access_token(%Client{} = client, code, opts) when is_binary(code) and is_list(opts) do
    body =
      %{
        grant_type: Keyword.get(opts, :grant_type, "authorization_code"),
        client_id: client.app_id,
        client_secret: Client.app_secret(client),
        code: code
      }
      |> maybe_put(:redirect_uri, Keyword.get(opts, :redirect_uri))

    FeishuOpenAPI.post(client, @oauth_token,
      body: body,
      access_token_type: nil
    )
    |> normalize_user_token()
  end

  @doc """
  Refresh a `user_access_token` using its `refresh_token`.
  """
  @spec refresh_user_access_token(Client.t(), String.t(), keyword() | String.t()) ::
          {:ok, user_token_resp()} | {:error, Error.t()}
  def refresh_user_access_token(client, refresh_token, opts \\ [])

  def refresh_user_access_token(%Client{} = client, refresh_token, grant_type)
      when is_binary(refresh_token) and is_binary(grant_type) do
    refresh_user_access_token(client, refresh_token, grant_type: grant_type)
  end

  def refresh_user_access_token(%Client{} = client, refresh_token, opts)
      when is_binary(refresh_token) and is_list(opts) do
    body = %{
      grant_type: Keyword.get(opts, :grant_type, "refresh_token"),
      client_id: client.app_id,
      client_secret: Client.app_secret(client),
      refresh_token: refresh_token
    }

    FeishuOpenAPI.post(client, @oauth_token,
      body: body,
      access_token_type: nil
    )
    |> normalize_user_token()
  end

  # --- internals -----------------------------------------------------------

  defp normalize({:ok, %{} = body}, token_field_snake) do
    token_key = Atom.to_string(token_field_snake)

    case body do
      %{"code" => 0, "expire" => expire} = b when is_integer(expire) ->
        case Map.get(b, token_key) do
          token when is_binary(token) ->
            {:ok, %{token: token, expire: expire}}

          _ ->
            {:error,
             %Error{
               code: :unexpected_shape,
               msg: "unexpected auth response",
               raw_body: body
             }}
        end

      _ ->
        {:error,
         %Error{
           code: Map.get(body, "code", :unexpected_shape),
           msg: Map.get(body, "msg", "unexpected auth response"),
           raw_body: body
         }}
    end
  end

  defp normalize({:error, _} = err, _), do: err

  defp normalize_user_token({:ok, %{"code" => 0, "data" => data}})
       when is_map(data) do
    normalize_user_token_data(data, %{"code" => 0, "data" => data})
  end

  defp normalize_user_token({:ok, %{"code" => 0} = body}) do
    normalize_user_token_data(body, body)
  end

  defp normalize_user_token({:ok, %{} = body}) do
    {:error,
     %Error{
       code: Map.get(body, "code", :unexpected_shape),
       msg: Map.get(body, "msg", "unexpected auth response"),
       raw_body: body
     }}
  end

  defp normalize_user_token({:error, _} = err), do: err

  defp normalize_user_token_data(data, raw_body) when is_map(data) do
    case Map.get(data, "access_token") do
      access_token when is_binary(access_token) ->
        {:ok,
         %{
           access_token: access_token,
           refresh_token: Map.get(data, "refresh_token"),
           token_type: Map.get(data, "token_type"),
           expires_in: Map.get(data, "expires_in"),
           refresh_expires_in:
             Map.get(data, "refresh_expires_in") || Map.get(data, "refresh_token_expires_in"),
           scope: Map.get(data, "scope"),
           raw: data
         }}

      _ ->
        {:error,
         %Error{
           code: :unexpected_shape,
           msg: "unexpected auth response",
           raw_body: raw_body
         }}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
