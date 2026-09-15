defmodule Ankole.Plugins.WhatsAppAdapter do
  @moduledoc "First-party WhatsApp consumer IM adapter on the Cloud API."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.WhatsAppAdapter.Config
  alias Ankole.Plugins.WhatsAppAdapter.Inbound
  alias Ankole.Plugins.WhatsAppAdapter.Outbox
  alias Ankole.Plugins.WhatsAppAdapter.Webhook

  @impl true
  def plugin_id, do: "whatsapp-adapter"

  @impl true
  def display_name, do: %{"default" => "WhatsApp Adapter", "zh-Hans-CN" => "WhatsApp 适配器"}

  @impl true
  def description do
    %{
      "default" =>
        "Connects a WhatsApp Business phone number through the Cloud API as a consumer IM signals provider.",
      "zh-Hans-CN" => "通过 Cloud API 连接 WhatsApp Business 电话号码，作为消费者 IM 信号提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "whatsapp",
        adapter_category: "consumer_im",
        plugin_id: plugin_id(),
        display_name: %{"default" => "WhatsApp"},
        config_key_pattern: "signals_gateway.whatsapp.bindings.<id>",
        config_module: Config,
        fields: [
          %{
            path: "appId",
            type: "string",
            required: true,
            encrypted: false,
            advanced: false,
            label: %{"default" => "App ID", "zh-Hans-CN" => "App ID"},
            description: %{
              "default" =>
                "Meta App ID that owns the WhatsApp product. It names the webhook URL segment. Several phone numbers of one App can share it.",
              "zh-Hans-CN" =>
                "拥有 WhatsApp 产品的 Meta App ID，也是 webhook URL 的路径段。同一个 App 下的多个电话号码可以共用它。"
            }
          },
          %{
            path: "appSecret",
            type: "secret",
            required: true,
            encrypted: true,
            advanced: false,
            label: %{"default" => "App secret", "zh-Hans-CN" => "App secret"},
            description: %{
              "default" =>
                "App secret used to verify the `x-hub-signature-256` webhook signature.",
              "zh-Hans-CN" => "用于校验 `x-hub-signature-256` webhook 签名的 App secret。"
            }
          },
          %{
            path: "verifyToken",
            type: "secret",
            required: true,
            encrypted: true,
            advanced: false,
            label: %{"default" => "Verify token", "zh-Hans-CN" => "Verify token"},
            description: %{
              "default" =>
                "String you choose and give to Meta. Ankole answers the subscription verification request only when it matches.",
              "zh-Hans-CN" => "由你自行设定并填入 Meta 的字符串。只有匹配时 Ankole 才会响应订阅校验请求。"
            }
          },
          %{
            path: "phoneNumberId",
            type: "string",
            required: true,
            encrypted: false,
            advanced: false,
            label: %{"default" => "Phone number ID", "zh-Hans-CN" => "电话号码 ID"},
            description: %{
              "default" =>
                "Phone number ID from the WhatsApp Manager. One phone number can serve one enabled binding.",
              "zh-Hans-CN" => "WhatsApp Manager 中的电话号码 ID。一个电话号码只能用于一条已启用的路由规则。"
            }
          },
          %{
            path: "accessToken",
            type: "secret",
            required: true,
            encrypted: true,
            advanced: false,
            label: %{"default" => "Access token", "zh-Hans-CN" => "Access token"},
            description: %{
              "default" =>
                "Permanent System User token with the `whatsapp_business_messaging` permission.",
              "zh-Hans-CN" => "具有 `whatsapp_business_messaging` 权限的系统用户永久访问令牌。"
            }
          }
        ],
        supported_group_message_modes: ["addressed_only"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        inbound_capabilities: ["entry_receive", "action_event"],
        outbound_capabilities: ["post_entry", "reply_entry", "divider", "card"]
      },
      %{
        contract_id: "signals_gateway.webhook_handler",
        id: "whatsapp",
        plugin_id: plugin_id(),
        module: Webhook,
        kinds: ["events"]
      }
    ]
  end

  @impl true
  def children do
    [{Task.Supervisor, name: Ankole.Plugins.WhatsAppAdapter.MaterializationTaskSupervisor}]
  end
end
