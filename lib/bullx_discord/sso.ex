defmodule BullXDiscord.SSO do
  @moduledoc """
  Discord OAuth2 browser login support for BullXWeb.
  """

  alias BullX.Config.Gateway, as: GatewayConfig
  alias BullXDiscord.{Config, Error}

  @authorize_url "https://discord.com/oauth2/authorize"
  @token_url "https://discord.com/api/oauth2/token"
  @user_url "https://discord.com/api/users/@me"

  @spec authorization_url(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def authorization_url(channel_id, redirect_uri, state, opts \\ [])
      when is_binary(channel_id) and is_binary(redirect_uri) and is_binary(state) do
    with {:ok, config} <- config_for_channel(channel_id, opts),
         :ok <- ensure_web_login_allowed(config) do
      {:ok, build_authorization_url(config, redirect_uri, state)}
    end
  end

  @spec login_from_callback(map(), keyword()) ::
          {:ok, %{user: BullXAccounts.User.t(), return_to: String.t()}} | {:error, term()}
  def login_from_callback(params, opts \\ []) when is_map(params) do
    channel_id = Map.get(params, "channel_id")
    redirect_uri = Map.get(params, "redirect_uri")

    with {:ok, code} <- callback_code(params),
         {:ok, config} <- config_for_channel(channel_id, opts),
         :ok <- ensure_web_login_allowed(config),
         {:ok, tokens} <- exchange_code(config, code, redirect_uri),
         {:ok, userinfo} <- fetch_userinfo(config, tokens["access_token"]),
         {:ok, input} <- provider_input(userinfo, config),
         {:ok, user, _binding} <- config.accounts_module.login_from_provider(input) do
      {:ok, %{user: user, return_to: callback_return_to(params)}}
    end
  end

  @spec config_for_channel(String.t(), keyword()) :: {:ok, Config.t()} | {:error, term()}
  def config_for_channel(channel_id, opts \\ [])

  def config_for_channel(channel_id, opts) when is_binary(channel_id) and channel_id != "" do
    case Keyword.get(opts, :config) do
      %Config{} = config -> {:ok, config}
      config when is_map(config) -> Config.normalize({:discord, channel_id}, config)
      nil -> configured_channel(channel_id)
    end
  end

  def config_for_channel(_channel_id, _opts), do: {:error, :invalid_channel_id}

  defp configured_channel(channel_id) do
    GatewayConfig.adapters()
    |> Enum.find_value(fn
      {{:discord, ^channel_id} = channel, BullXDiscord.Adapter, config} -> {channel, config}
      {{"discord", ^channel_id}, BullXDiscord.Adapter, config} -> {{:discord, channel_id}, config}
      _other -> nil
    end)
    |> case do
      nil -> {:error, :discord_channel_not_configured}
      {channel, config} -> Config.normalize(channel, config)
    end
  end

  defp ensure_web_login_allowed(%Config{} = config) do
    case Config.web_login_allowed?(config) do
      true -> :ok
      false -> {:error, :web_login_disabled}
    end
  end

  defp callback_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp callback_code(_params), do: {:error, :missing_code}

  defp callback_return_to(%{"return_to" => return_to}) when is_binary(return_to), do: return_to
  defp callback_return_to(_params), do: "/"

  defp build_authorization_url(%Config{} = config, redirect_uri, state) do
    query =
      URI.encode_query(%{
        "client_id" => config.application_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(config.sso.scopes, " "),
        "state" => state
      })

    @authorize_url <> "?" <> query
  end

  defp exchange_code(%Config{} = config, code, redirect_uri) do
    body = %{
      "client_id" => config.application_id,
      "client_secret" => Config.secret_value(config.client_secret),
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => redirect_uri
    }

    [url: @token_url, form: body]
    |> Keyword.merge(config.req_options)
    |> Req.post()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{} = response} ->
        {:error, Error.map(response)}

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp fetch_userinfo(%Config{}, nil), do: {:error, :missing_access_token}

  defp fetch_userinfo(%Config{} = config, access_token) do
    [url: @user_url, auth: {:bearer, access_token}]
    |> Keyword.merge(config.req_options)
    |> Req.get()
    |> case do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{} = response} ->
        {:error, Error.map(response)}

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp provider_input(userinfo, %Config{} = config) do
    case Map.get(userinfo, "id") do
      id when is_binary(id) and id != "" ->
        {:ok,
         %{
           provider: :discord,
           provider_user_id: id,
           adapter: :discord,
           channel_id: config.channel_id,
           external_id: "discord:" <> id,
           profile: profile(userinfo),
           metadata:
             %{
               "channel_id" => config.channel_id,
               "locale" => Map.get(userinfo, "locale"),
               "verified_email" => verified_email?(userinfo)
             }
             |> reject_nil_values()
         }}

      _other ->
        {:error, :missing_discord_user_id}
    end
  end

  defp profile(userinfo) do
    %{}
    |> maybe_put("display_name", first_string(userinfo, ["global_name", "username"]))
    |> maybe_put("username", Map.get(userinfo, "username"))
    |> maybe_put("email", verified_email(userinfo))
    |> maybe_put("avatar_url", avatar_url(userinfo))
    |> maybe_put("user_id", Map.get(userinfo, "id"))
  end

  defp verified_email(%{"verified" => true, "email" => email})
       when is_binary(email) and email != "",
       do: email

  defp verified_email(_userinfo), do: nil

  defp verified_email?(userinfo), do: not is_nil(verified_email(userinfo))

  defp avatar_url(%{"id" => id, "avatar" => avatar}) when is_binary(id) and is_binary(avatar) do
    "https://cdn.discordapp.com/avatars/#{id}/#{avatar}.webp"
  end

  defp avatar_url(_userinfo), do: nil

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _other -> nil
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
