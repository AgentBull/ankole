defmodule WeComOpenAPI.OAuth do
  @moduledoc """
  WeCom WWLogin (Web login) helpers for the self-built-app login chain.

  The chain is: WWLogin page (`login_type=CorpApp`) → redirect `code` (5
  minutes, single use) → `GET /cgi-bin/auth/getuserinfo` with the self-built
  app's access token → enterprise `userid`. Non-members answer with `openid`
  and linked-corp members answer with a `CorpId/userid` shape; both are
  surfaced as `{:error, :non_member}` so login stays fail-closed.
  """

  alias WeComOpenAPI.{Corp.Client, Error}

  # Fixed per the official Web-login docs; the login host is not the API domain.
  # Overridable via `:authorize_url` for local end-to-end fakes.
  @authorize_url "https://login.work.weixin.qq.com/wwlogin/sso/login"
  @getuserinfo_path "/cgi-bin/auth/getuserinfo"

  @doc """
  Build the WWLogin page URL. Options:

    * `:corp_id` (required) — enterprise CorpID (the `appid` parameter).
    * `:agentid` (required) — self-built app AgentId.
    * `:redirect_uri` (required) — must be under the app's trusted domain.
    * `:state` (required) — anti-forgery value round-tripped back on redirect.
    * `:lang` — `"zh"` (default) or `"en"`.
    * `:authorize_url` — override the base (local fakes only).
  """
  @spec authorize_url(keyword()) :: String.t()
  def authorize_url(opts) do
    params = %{
      login_type: "CorpApp",
      appid: Keyword.fetch!(opts, :corp_id),
      agentid: Keyword.fetch!(opts, :agentid),
      redirect_uri: Keyword.fetch!(opts, :redirect_uri),
      state: Keyword.fetch!(opts, :state),
      lang: Keyword.get(opts, :lang, "zh")
    }

    Keyword.get(opts, :authorize_url, @authorize_url) <> "?" <> URI.encode_query(params)
  end

  @doc """
  Exchange a redirect `code` for the visiting member's identity using the
  self-built app's access token. Returns `{:ok, %{userid: userid, raw: body}}`
  for an enterprise member; `{:error, :non_member}` for `openid` (non-member)
  and linked-corp (`CorpId/userid`) responses.
  """
  @spec get_user_info(Client.t(), String.t()) ::
          {:ok, %{userid: String.t(), raw: map()}} | {:error, :non_member | Error.t()}
  def get_user_info(%Client{} = client, code) when is_binary(code) do
    case WeComOpenAPI.get(client, @getuserinfo_path, query: [code: code]) do
      {:ok, %{"userid" => userid} = body} when is_binary(userid) and userid != "" ->
        if String.contains?(userid, "/") do
          {:error, :non_member}
        else
          {:ok, %{userid: userid, raw: body}}
        end

      {:ok, %{"openid" => openid}} when is_binary(openid) ->
        {:error, :non_member}

      {:ok, other} ->
        {:error, %Error{reason: :unexpected_shape, raw: other}}

      {:error, _reason} = error ->
        error
    end
  end
end
