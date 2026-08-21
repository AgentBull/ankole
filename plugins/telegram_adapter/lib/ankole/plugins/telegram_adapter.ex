defmodule Ankole.Plugins.TelegramAdapter do
  @moduledoc "First-party Telegram consumer IM adapter."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.TelegramAdapter.Config
  alias Ankole.Plugins.TelegramAdapter.ConnectionReconciler
  alias Ankole.Plugins.TelegramAdapter.ConnectionSupervisor
  alias Ankole.Plugins.TelegramAdapter.Inbound
  alias Ankole.Plugins.TelegramAdapter.Outbox
  alias Ankole.Plugins.TelegramAdapter.ReplyPreview

  @impl true
  def plugin_id, do: "telegram-adapter"

  @impl true
  def display_name,
    do: %{"default" => "Telegram Adapter", "zh-Hans-CN" => "Telegram 适配器"}

  @impl true
  def description do
    %{
      "default" => "Connects a Telegram bot as a consumer IM signals provider.",
      "zh-Hans-CN" => "连接 Telegram Bot，作为消费者 IM 信号提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "telegram",
        adapter_category: "consumer_im",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Telegram"},
        config_key_pattern: "signals_gateway.telegram.bindings.<id>",
        config_module: Config,
        fields: [
          %{
            path: "botToken",
            type: "secret",
            required: true,
            encrypted: true,
            advanced: false,
            label: %{"default" => "Bot token", "zh-Hans-CN" => "Bot Token"},
            description: %{
              "default" => "Token issued by BotFather. One token can serve one enabled binding.",
              "zh-Hans-CN" => "由 BotFather 签发。一个 Token 只能用于一条已启用的路由规则。"
            }
          }
        ],
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        reply_preview_module: ReplyPreview,
        connection_supervisor: ConnectionSupervisor,
        inbound_capabilities: [
          "entry_receive",
          "reaction_add",
          "reaction_remove",
          "action_event"
        ],
        outbound_capabilities: [
          "post_entry",
          "reply_entry",
          "edit_entry",
          "delete_entry",
          "add_reaction",
          "remove_reaction",
          "divider",
          "card"
        ]
      }
    ]
  end

  @impl true
  def children do
    [
      {Registry, keys: :unique, name: Ankole.Plugins.TelegramAdapter.ConnectionRegistry},
      {Task.Supervisor, name: Ankole.Plugins.TelegramAdapter.PollTaskSupervisor},
      {DynamicSupervisor,
       name: Ankole.Plugins.TelegramAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
      ConnectionReconciler
    ]
  end
end
