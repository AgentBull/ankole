defmodule BullXWeb.Sessions do
  @moduledoc false

  use Phoenix.VerifiedRoutes,
    endpoint: BullXWeb.Endpoint,
    router: BullXWeb.Router,
    statics: BullXWeb.static_paths()

  import Plug.Conn, only: [clear_session: 1, configure_session: 2]

  alias BullXDiscord.Config, as: DiscordConfig
  alias BullXFeishu.Config, as: FeishuConfig

  @login_providers_cache_key {__MODULE__, :login_providers}
  @reserved_channel_ids ~w(new)
  @providers ~w(feishu discord)

  @spec callback_origin() :: String.t()
  def callback_origin do
    BullXWeb.Endpoint.url()
    |> String.trim_trailing("/")
  end

  @spec callback_url(String.t() | atom(), String.t()) :: String.t()
  def callback_url(provider, channel_id) when is_binary(channel_id) do
    provider = normalize_provider(provider)
    callback_origin() <> provider_callback_path(provider, channel_id)
  end

  @spec login_providers() :: [map()]
  def login_providers do
    adapters = BullX.Config.Gateway.adapters()
    fingerprint = :erlang.phash2(adapters)

    case :persistent_term.get(@login_providers_cache_key, :none) do
      {^fingerprint, providers} ->
        providers

      _other ->
        providers = build_login_providers(adapters)
        :persistent_term.put(@login_providers_cache_key, {fingerprint, providers})
        providers
    end
  end

  @spec renew_session(Plug.Conn.t()) :: Plug.Conn.t()
  def renew_session(conn) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  @spec route_safe_channel_id?(term()) :: boolean()
  def route_safe_channel_id?(channel_id) when channel_id in @reserved_channel_ids, do: false

  def route_safe_channel_id?(channel_id) when is_binary(channel_id),
    do: channel_id != "" and not String.contains?(channel_id, "/")

  def route_safe_channel_id?(_channel_id), do: false

  @spec safe_return_to(term()) :: String.t()
  def safe_return_to(path) when is_binary(path) do
    uri = URI.parse(path)

    cond do
      uri.scheme != nil or uri.host != nil -> "/"
      not String.starts_with?(path, "/") -> "/"
      String.starts_with?(path, "//") -> "/"
      true -> path
    end
  end

  def safe_return_to(_path), do: "/"

  defp build_login_providers(adapters) do
    Enum.flat_map(adapters, &login_provider/1)
  end

  defp login_provider({{adapter, channel_id}, BullXFeishu.Adapter, config})
       when adapter in [:feishu, "feishu"] and is_binary(channel_id) do
    with true <- route_safe_channel_id?(channel_id),
         {:ok, config} <- FeishuConfig.normalize({:feishu, channel_id}, config),
         true <- FeishuConfig.web_login_allowed?(config) do
      [
        %{
          id: "feishu:#{channel_id}",
          provider: "feishu",
          channel_id: channel_id,
          label: provider_label(config),
          href: ~p"/sessions/feishu/#{channel_id}"
        }
      ]
    else
      _other -> []
    end
  end

  defp login_provider({{adapter, channel_id}, BullXDiscord.Adapter, config})
       when adapter in [:discord, "discord"] and is_binary(channel_id) do
    with true <- route_safe_channel_id?(channel_id),
         {:ok, config} <- DiscordConfig.normalize({:discord, channel_id}, config),
         true <- DiscordConfig.web_login_allowed?(config) do
      [
        %{
          id: "discord:#{channel_id}",
          provider: "discord",
          channel_id: channel_id,
          label: "Discord · #{channel_id}",
          href: ~p"/sessions/discord/#{channel_id}"
        }
      ]
    else
      _other -> []
    end
  end

  defp login_provider(_adapter), do: []

  defp provider_label(%FeishuConfig{domain: :lark, channel_id: channel_id}),
    do: "Lark · #{channel_id}"

  defp provider_label(%FeishuConfig{channel_id: channel_id}), do: "Feishu · #{channel_id}"

  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(provider) when provider in @providers, do: provider
  defp normalize_provider(_provider), do: "feishu"

  defp provider_callback_path("discord", channel_id),
    do: ~p"/sessions/discord/#{channel_id}/callback"

  defp provider_callback_path(_provider, channel_id),
    do: ~p"/sessions/feishu/#{channel_id}/callback"
end
