defmodule Ankole.Plugins.DiscordAdapter do
  @moduledoc "First-party Discord consumer IM adapter."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.DiscordAdapter.Config
  alias Ankole.Plugins.DiscordAdapter.ConnectionReconciler
  alias Ankole.Plugins.DiscordAdapter.ConnectionSupervisor
  alias Ankole.Plugins.DiscordAdapter.Inbound
  alias Ankole.Plugins.DiscordAdapter.Outbox
  alias Ankole.Plugins.DiscordAdapter.ReplyPreview

  @impl true
  def plugin_id, do: "discord-adapter"

  @impl true
  def display_name, do: %{"default" => "Discord Adapter", "zh-Hans-CN" => "Discord 适配器"}

  @impl true
  def description do
    %{
      "default" => "Connects a Discord bot as a consumer IM signals provider.",
      "zh-Hans-CN" => "连接 Discord Bot，作为消费者 IM 信号提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "discord",
        adapter_category: "consumer_im",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Discord"},
        config_key_pattern: "signals_gateway.discord.bindings.<id>",
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
              "default" =>
                "Token from the Discord Developer Portal. One token can serve one enabled binding.",
              "zh-Hans-CN" => "来自 Discord 开发者门户。一个 Token 只能用于一条已启用的路由规则。"
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
      {Registry, keys: :unique, name: Ankole.Plugins.DiscordAdapter.ConnectionRegistry},
      {Task.Supervisor, name: Ankole.Plugins.DiscordAdapter.EventTaskSupervisor},
      {DynamicSupervisor,
       name: Ankole.Plugins.DiscordAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
      ConnectionReconciler
    ]
  end
end
