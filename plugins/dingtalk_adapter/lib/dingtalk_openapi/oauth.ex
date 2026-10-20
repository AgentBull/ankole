defmodule DingTalkOpenAPI.OAuth do
  @moduledoc """
  DingTalk authorization-code login helpers.

  The login chain is: authorize page → `authCode` (note: the redirect parameter
  is `authCode`, not `code`) → user access token (with the chosen org `corpId`)
  → `contact/users/me` (unionId, profile) → `topapi/user/getbyunionid` (the
  enterprise `userid`). The enterprise `userid` is the canonical platform
  subject id, shared with chat inbound `senderStaffId`.
  """

  alias DingTalkOpenAPI.{Client, Error}

  # Fixed per the official login sample code; the authorize host is not the API
  # domain. Overridable via `:authorize_url` for local end-to-end fakes.
  @authorize_url "https://login.dingtalk.com/oauth2/auth"
  @user_token_path "/v1.0/oauth2/userAccessToken"
  @me_path "/v1.0/contact/users/me"
  @getbyunionid_path "topapi/user/getbyunionid"

  @doc """
  Build the authorization page URL. Options:

    * `:client_id` (required) — AppKey.
    * `:redirect_uri` (required) — must match the console's registered redirect.
    * `:state` (required) — anti-forgery value round-tripped back on redirect.
    * `:scope` — `"openid"` or `"openid corpid"` (default). Only these two are
      valid platform values; `corpid` returns the chosen org's `corpId`.
    * `:prompt` — default `"consent"`.
    * `:authorize_url` — override the base (local fakes only).
  """
  @spec authorize_url(keyword()) :: String.t()
  def authorize_url(opts) do
    params =
      %{
        redirect_uri: Keyword.fetch!(opts, :redirect_uri),
        response_type: "code",
        client_id: Keyword.fetch!(opts, :client_id),
        scope: Keyword.get(opts, :scope, "openid corpid"),
        prompt: Keyword.get(opts, :prompt, "consent"),
        state: Keyword.fetch!(opts, :state)
      }

    Keyword.get(opts, :authorize_url, @authorize_url) <> "?" <> URI.encode_query(params)
  end

  @doc """
  Exchange a redirect `authCode` for a user access token. Returns
  `%{access_token, refresh_token, expires_in, corp_id, raw}`.
  """
  @spec exchange_code(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def exchange_code(%Client{} = client, auth_code) when is_binary(auth_code) do
    body = %{
      "clientId" => client.client_id,
      "clientSecret" => Client.client_secret(client),
      "code" => auth_code,
      "grantType" => "authorization_code"
    }

    with {:ok, %{"accessToken" => token} = data} when is_binary(token) <-
           DingTalkOpenAPI.post(client, @user_token_path, body: body, token: nil) do
      {:ok,
       %{
         access_token: token,
         refresh_token: Map.get(data, "refreshToken"),
         expires_in: Map.get(data, "expireIn"),
         corp_id: Map.get(data, "corpId"),
         raw: data
       }}
    else
      {:ok, other} -> {:error, %Error{reason: :unexpected_shape, raw: other}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetch the logged-in user's contact profile with their user access token."
  @spec me(Client.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def me(%Client{} = client, user_access_token) when is_binary(user_access_token) do
    DingTalkOpenAPI.get(client, @me_path, token: {:user, user_access_token})
  end

  @doc """
  Resolve an enterprise `userid` from a `unionId` using the app token. Returns
  `{:ok, userid}`; a `60121` (unionid has no employee) surfaces as
  `%Error{reason: :not_found}`.
  """
  @spec get_userid_by_unionid(Client.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def get_userid_by_unionid(%Client{} = client, union_id) when is_binary(union_id) do
    case DingTalkOpenAPI.post(client, @getbyunionid_path, body: %{"unionid" => union_id}) do
      {:ok, %{"result" => %{"userid" => userid}}} when is_binary(userid) ->
        {:ok, userid}

      {:ok, other} ->
        {:error, %Error{reason: :unexpected_shape, raw: other}}

      {:error, _reason} = error ->
        error
    end
  end
end
