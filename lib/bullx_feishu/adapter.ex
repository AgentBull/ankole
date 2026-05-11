defmodule BullXFeishu.Adapter do
  @moduledoc """
  Gateway adapter implementation for Feishu/Lark.
  """

  @behaviour BullXGateway.Adapter

  alias BullXGateway.Delivery, as: GatewayDelivery
  alias BullXFeishu.{Channel, Config, Delivery, StreamingCard}

  @impl true
  def adapter_id, do: :feishu

  @impl true
  def config_docs do
    %{
      "en-US" => "https://github.com/AgentBull/bullx/blob/main/docs/channels/feishu.en-US.md",
      "zh-Hans-CN" =>
        "https://github.com/AgentBull/bullx/blob/main/docs/channels/feishu.zh-Hans-CN.md"
    }
  end

  @impl true
  def capabilities, do: [:send, :edit, :stream, :cards, :threads, :reactions]

  @impl true
  def connectivity_check(channel, config) do
    with {:ok, cfg} <- Config.normalize(channel, config),
         {:ok, client} <- safe_client(cfg),
         {:ok, token} <- verify_credentials(cfg, client) do
      {:ok,
       %{
         "adapter" => "feishu",
         "channel_id" => cfg.channel_id,
         "app_id" => cfg.app_id,
         "domain" => to_string(cfg.domain),
         "capabilities" => Enum.map(capabilities(), &Atom.to_string/1),
         "credential" => %{
           "status" => "verified",
           "expires_in_seconds" => token.expire
         },
         "transport" => transport_check_result(cfg)
       }}
    else
      {:error, %{} = error} -> {:error, safe_connectivity_error(error)}
    end
  end

  @impl true
  def child_specs(channel, config) do
    cfg = Config.normalize!(channel, config)

    [{Channel, {channel, cfg}}] ++ transport_children(channel, cfg)
  end

  @impl true
  def deliver(%GatewayDelivery{} = delivery, %{channel: channel, config: config}) do
    with {:ok, cfg} <- Config.normalize(channel, config) do
      Delivery.deliver(delivery, cfg)
    end
  end

  @impl true
  def stream(%GatewayDelivery{} = delivery, enumerable, %{channel: channel, config: config}) do
    with {:ok, cfg} <- Config.normalize(channel, config) do
      StreamingCard.stream(delivery, enumerable, cfg)
    end
  end

  defp transport_children(_channel, %Config{start_transport?: false}), do: []

  defp transport_children(channel, %Config{} = config) do
    [
      %{
        id: {FeishuOpenAPI.WS.Client, channel},
        start:
          {FeishuOpenAPI.WS.Client, :start_link,
           [
             [
               client: Config.client!(config),
               dispatcher: Channel.event_dispatcher(channel, config),
               name: Channel.transport_via({FeishuOpenAPI.WS.Client, channel})
             ]
           ]},
        restart: :permanent,
        type: :worker
      }
    ]
  end

  defp safe_client(%Config{} = config) do
    {:ok, Config.client!(config)}
  rescue
    e in ArgumentError ->
      {:error,
       %{
         "kind" => "config",
         "message" => Exception.message(e),
         "details" => %{"field" => "adapter"}
       }}
  end

  defp verify_credentials(%Config{}, client) do
    FeishuOpenAPI.Auth.tenant_access_token(client)
  end

  defp transport_check_result(%Config{}) do
    %{
      "mode" => "websocket",
      "status" => "credentials_verified",
      "long_lived_client_started" => false
    }
  end

  defp safe_connectivity_error(%{"kind" => kind} = error)
       when kind in ["auth", "config", "network", "rate_limit", "unknown"] do
    error
  end

  defp safe_connectivity_error(%{"message" => message, "details" => details}) do
    %{"kind" => "config", "message" => message, "details" => details}
  end

  defp safe_connectivity_error(%FeishuOpenAPI.Error{} = error) do
    %{
      "kind" => feishu_error_kind(error),
      "message" => feishu_error_message(error),
      "details" => %{
        "code" => error.code,
        "http_status" => error.http_status,
        "log_id" => error.log_id
      }
    }
  end

  defp safe_connectivity_error(error) do
    %{"kind" => "unknown", "message" => inspect(error), "details" => %{}}
  end

  defp feishu_error_kind(%FeishuOpenAPI.Error{code: :transport}), do: "network"
  defp feishu_error_kind(%FeishuOpenAPI.Error{code: :rate_limited}), do: "rate_limit"
  defp feishu_error_kind(%FeishuOpenAPI.Error{code: code}) when is_integer(code), do: "auth"
  defp feishu_error_kind(%FeishuOpenAPI.Error{}), do: "unknown"

  defp feishu_error_message(%FeishuOpenAPI.Error{msg: msg}) when is_binary(msg), do: msg
  defp feishu_error_message(%FeishuOpenAPI.Error{} = error), do: Exception.message(error)
end
