defmodule BullXWeb.Sessions do
  @moduledoc false

  use Phoenix.VerifiedRoutes,
    endpoint: BullXWeb.Endpoint,
    router: BullXWeb.Router,
    statics: BullXWeb.static_paths()

  import Plug.Conn, only: [clear_session: 1, configure_session: 2]

  alias BullXFeishu.Config, as: FeishuConfig

  @login_providers_cache_key {__MODULE__, :login_providers}
  @reserved_channel_ids ~w(new)

  @spec callback_origin() :: String.t()
  def callback_origin do
    BullXWeb.Endpoint.url()
    |> String.trim_trailing("/")
  end

  @spec callback_url(String.t()) :: String.t()
  def callback_url(channel_id) when is_binary(channel_id) do
    callback_origin() <> ~p"/sessions/#{channel_id}/callback"
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
          href: ~p"/sessions/#{channel_id}"
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
end
