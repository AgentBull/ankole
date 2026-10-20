defmodule SlackOpenAPI.OIDC do
  @moduledoc "Sign in with Slack OIDC helpers."

  alias SlackOpenAPI.Client

  @authorize_url "https://slack.com/openid/connect/authorize"

  @spec authorize_url(keyword()) :: String.t()
  def authorize_url(opts) do
    params =
      %{
        response_type: "code",
        scope: Enum.join(Keyword.get(opts, :scopes, ["openid", "profile", "email"]), " "),
        client_id: Keyword.fetch!(opts, :client_id),
        redirect_uri: Keyword.fetch!(opts, :redirect_uri),
        state: Keyword.fetch!(opts, :state)
      }
      |> maybe_put(:team, Keyword.get(opts, :team))

    Keyword.get(opts, :authorize_url, @authorize_url) <> "?" <> URI.encode_query(params)
  end

  @spec exchange_code(Client.t() | nil, keyword()) ::
          {:ok, map()} | {:error, SlackOpenAPI.Error.t()}
  def exchange_code(client \\ nil, opts) do
    client = client || Client.new(base_url: Keyword.get(opts, :base_url, "https://slack.com/api"))

    with {:ok, body} <-
           SlackOpenAPI.post(client, "openid.connect.token",
             form: [
               client_id: Keyword.fetch!(opts, :client_id),
               client_secret: Keyword.fetch!(opts, :client_secret),
               code: Keyword.fetch!(opts, :code),
               redirect_uri: Keyword.fetch!(opts, :redirect_uri),
               grant_type: "authorization_code"
             ],
             token: nil
           ) do
      {:ok,
       %{
         access_token: Map.get(body, "access_token"),
         id_token: Map.get(body, "id_token"),
         raw: body
       }}
    end
  end

  @spec user_info(String.t(), keyword()) :: {:ok, map()} | {:error, SlackOpenAPI.Error.t()}
  def user_info(access_token, opts \\ []) do
    client =
      Client.new(
        base_url: Keyword.get(opts, :base_url, "https://slack.com/api"),
        req_options: Keyword.get(opts, :req_options, [])
      )

    SlackOpenAPI.post(client, "openid.connect.userInfo",
      body: %{},
      token: {:bearer, access_token}
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
