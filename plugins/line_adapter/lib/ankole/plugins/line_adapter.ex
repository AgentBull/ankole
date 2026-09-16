defmodule Ankole.Plugins.LineAdapter do
  @moduledoc "First-party LINE consumer IM adapter."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.LineAdapter.Config
  alias Ankole.Plugins.LineAdapter.Inbound
  alias Ankole.Plugins.LineAdapter.Outbox
  alias Ankole.Plugins.LineAdapter.Profile
  alias Ankole.Plugins.LineAdapter.Webhook

  @impl true
  def plugin_id, do: "line-adapter"

  @impl true
  def display_name, do: %{"default" => "LINE Adapter", "zh-Hans-CN" => "LINE 适配器"}

  @impl true
  def description do
    %{
      "default" =>
        "Connects a LINE Official Account through the Messaging API as a consumer IM signals provider.",
      "zh-Hans-CN" => "通过 Messaging API 连接 LINE 官方账号，作为消费者 IM 信号提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "line",
        adapter_category: "consumer_im",
        plugin_id: plugin_id(),
        display_name: %{"default" => "LINE"},
        config_key_pattern: "signals_gateway.line.bindings.<id>",
        config_module: Config,
        fields: [
          %{
            path: "channelId",
            type: "string",
            required: true,
            encrypted: false,
            advanced: false,
            label: %{"default" => "Channel ID", "zh-Hans-CN" => "Channel ID"},
            description: %{
              "default" =>
                "Messaging API channel ID from the LINE Developers Console. It names the webhook URL segment. One channel can serve one enabled binding.",
              "zh-Hans-CN" =>
                "LINE Developers Console 中 Messaging API channel 的 ID，也是 webhook URL 的路径段。一个 channel 只能用于一条已启用的路由规则。"
            }
          },
          %{
            path: "channelSecret",
            type: "secret",
            required: true,
            encrypted: true,
            advanced: false,
            label: %{"default" => "Channel secret", "zh-Hans-CN" => "Channel secret"},
            description: %{
              "default" => "Channel secret used to verify the webhook signature.",
              "zh-Hans-CN" => "用于校验 webhook 签名的 channel secret。"
            }
          },
          %{
            path: "channelAccessToken",
            type: "secret",
            required: true,
            encrypted: true,
            advanced: false,
            label: %{"default" => "Channel access token", "zh-Hans-CN" => "Channel access token"},
            description: %{
              "default" =>
                "Long-lived channel access token issued in the LINE Developers Console.",
              "zh-Hans-CN" => "在 LINE Developers Console 签发的长期 channel access token。"
            }
          }
        ],
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        author_hydrator: Profile,
        inbound_capabilities: ["entry_receive", "entry_removed", "action_event"],
        outbound_capabilities: [
          "post_entry",
          "reply_entry",
          "divider",
          "card",
          "outbound_reconciliation"
        ]
      },
      %{
        contract_id: "signals_gateway.webhook_handler",
        id: "line",
        plugin_id: plugin_id(),
        module: Webhook,
        kinds: ["events"]
      }
    ]
  end

  @impl true
  def children do
    [{Task.Supervisor, name: Ankole.Plugins.LineAdapter.MaterializationTaskSupervisor}]
  end
end
