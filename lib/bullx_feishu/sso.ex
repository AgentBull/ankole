defmodule BullXFeishu.SSO do
  @moduledoc """
  Feishu OIDC browser login support for BullXWeb.

  The first implementation exchanges the Feishu authorization code, fetches
  userinfo, normalizes the same channel-local `external_id` used by IM events,
  and discards Feishu user tokens after login.
  """

  alias BullX.Config.Gateway, as: GatewayConfig
  alias BullXFeishu.Config
  alias FeishuOpenAPI.Auth

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
         {:ok, tokens} <-
           Auth.user_access_token(Config.client!(config), code, redirect_uri: redirect_uri),
         {:ok, userinfo} <- fetch_userinfo(config, tokens.access_token),
         {:ok, input} <- provider_input(userinfo, config),
         {:ok, user, _binding} <- config.accounts_module.login_from_provider(input) do
      {:ok, %{user: user, return_to: callback_return_to(params)}}
    end
  end

  @spec config_for_channel(String.t(), keyword()) :: {:ok, Config.t()} | {:error, term()}
  def config_for_channel(channel_id, opts \\ [])

  def config_for_channel(channel_id, opts) when is_binary(channel_id) and channel_id != "" do
    case Keyword.get(opts, :config) do
      %Config{} = config ->
        {:ok, config}

      config when is_map(config) ->
        Config.normalize({:feishu, channel_id}, config)

      nil ->
        configured_channel(channel_id)
    end
  end

  def config_for_channel(_channel_id, _opts), do: {:error, :invalid_channel_id}

  defp configured_channel(channel_id) do
    GatewayConfig.adapters()
    |> Enum.find_value(fn
      {{:feishu, ^channel_id} = channel, BullXFeishu.Adapter, config} -> {channel, config}
      {{"feishu", ^channel_id}, BullXFeishu.Adapter, config} -> {{:feishu, channel_id}, config}
      _ -> nil
    end)
    |> case do
      nil -> {:error, :feishu_channel_not_configured}
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
  defp callback_code(_), do: {:error, :missing_code}

  defp callback_return_to(%{"return_to" => return_to}) when is_binary(return_to), do: return_to
  defp callback_return_to(_params), do: "/"

  defp fetch_userinfo(%Config{} = config, access_token) do
    case FeishuOpenAPI.get(Config.client!(config), "/open-apis/authen/v1/user_info",
           user_access_token: access_token
         ) do
      {:ok, %{"data" => data}} when is_map(data) -> {:ok, data}
      {:ok, data} when is_map(data) -> {:ok, data}
      {:error, error} -> {:error, BullXFeishu.Error.map(error)}
    end
  end

  defp provider_input(userinfo, %Config{} = config) do
    case Map.get(userinfo, "open_id") do
      open_id when is_binary(open_id) and open_id != "" ->
        {:ok,
         %{
           provider: :feishu,
           provider_user_id: open_id,
           adapter: :feishu,
           channel_id: config.channel_id,
           external_id: "feishu:" <> open_id,
           profile: profile(userinfo),
           metadata:
             %{
               "channel_id" => config.channel_id,
               "tenant_key" => Map.get(userinfo, "tenant_key"),
               "domain" => to_string(config.domain)
             }
             |> reject_nil_values()
         }}

      _ ->
        {:error, :missing_open_id}
    end
  end

  defp profile(userinfo) do
    %{}
    |> maybe_put("display_name", first_string(userinfo, ["name", "display_name", "en_name"]))
    |> maybe_put("email", first_string(userinfo, ["email"]))
    |> maybe_put_phone(first_string(userinfo, ["mobile", "phone"]))
    |> maybe_put(
      "avatar_url",
      first_string(userinfo, ["avatar_url", "avatar_thumb", "avatar_middle"])
    )
    |> maybe_put("open_id", Map.get(userinfo, "open_id"))
    |> maybe_put("union_id", Map.get(userinfo, "union_id"))
    |> maybe_put("user_id", Map.get(userinfo, "user_id"))
  end

  defp build_authorization_url(%Config{} = config, redirect_uri, state) do
    query =
      URI.encode_query(%{
        "client_id" => config.app_id,
        "redirect_uri" => redirect_uri,
        "response_type" => "code",
        "scope" => Enum.join(config.sso.scopes, " "),
        "state" => state
      })

    authorize_base(config.domain) <> "/open-apis/authen/v1/authorize?" <> query
  end

  defp authorize_base(:feishu), do: "https://accounts.feishu.cn"
  defp authorize_base(:lark), do: "https://accounts.larksuite.com"
  defp authorize_base(domain) when is_binary(domain), do: String.trim_trailing(domain, "/")

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp maybe_put_phone(map, nil), do: map

  defp maybe_put_phone(map, phone) do
    phone
    |> phone_candidates()
    |> Enum.find_value(fn candidate ->
      case BullX.Ext.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        _ -> nil
      end
    end)
    |> case do
      nil -> map
      normalized -> Map.put(map, "phone", normalized)
    end
  end

  defp phone_candidates(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    if String.length(digits) == 11 and String.starts_with?(digits, "1") do
      [trimmed, "+86" <> digits]
    else
      [trimmed]
    end
  end
end
