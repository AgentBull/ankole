defmodule Ankole.Plugins.SlackAdapter do
  @moduledoc "First-party Slack chat and identity-provider plugin."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.SlackAdapter.{Channels, Config, ConnectionReconciler}
  alias Ankole.Plugins.SlackAdapter.{ConnectionSupervisor, IdentityProvider, Inbound, Outbox}

  @zh_fields %{
    "botToken" => {"Bot Token", "用于聊天或目录同步的 Bot User OAuth Token。"},
    "appToken" => {"App Token", "带 connections:write 权限的 App-Level Token。"},
    "platformSubjectNamespace" => {"平台主体命名空间", "每个 Slack workspace 使用一个命名空间。"},
    "userName" => {"输出显示名", "出站消息使用的显示名称。"},
    "clientID" => {"Client ID", "Slack 应用的 Client ID。"},
    "clientSecret" => {"Client Secret", "Slack 应用的 Client Secret。"},
    "teamID" => {"Workspace ID", "可选，登录时限定 workspace。"},
    "oidc.enabled" => {"启用 OIDC", "允许使用 Slack 登录。"},
    "oidc.scopes" => {"OIDC 权限范围", "登录时请求的 scope。"},
    "sync.contacts" => {"同步目录", "导入 Slack 用户与 usergroup。"},
    "sync.websocket" => {"实时目录同步", "通过 Socket Mode 消费目录事件。"},
    "sync.pageSize" => {"同步分页大小", "users.list 的 cursor 分页大小。"}
  }

  @impl true
  def plugin_id, do: "slack-adapter"

  @impl true
  def display_name,
    do: %{"default" => "Slack Adapter", "zh-Hans-CN" => "Slack 适配器"}

  @impl true
  def description do
    %{
      "default" => "Connects a Slack app as a signals provider and login provider.",
      "zh-Hans-CN" => "连接 Slack 应用作为信号提供方与登录提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "slack",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Slack"},
        config_key_pattern: "signals_gateway.slack.bindings.<id>",
        config_module: Config,
        fields: chat_fields(),
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        connection_supervisor: ConnectionSupervisor,
        binding_saved_module: Channels,
        inbound_capabilities: [
          "entry_receive",
          "entry_removed",
          "reaction_add",
          "reaction_remove",
          "action_event"
        ],
        outbound_capabilities: [
          "post_entry",
          "reply_entry",
          "edit_entry",
          "delete_entry",
          "outbound_reconciliation",
          "add_reaction",
          "remove_reaction",
          "divider",
          "card"
        ]
      },
      %{
        contract_id: "principals.identity_provider",
        id: "slack",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Slack"},
        config_key_pattern: "principals.identity_providers.slack.<id>",
        fields: identity_fields(),
        module: IdentityProvider,
        connection_reconciler: ConnectionReconciler,
        capabilities: [
          "oidc_authorization",
          "oidc_code_exchange",
          "directory_full_sync",
          "directory_realtime_sync"
        ]
      }
    ]
  end

  @impl true
  def children do
    [
      {Registry, keys: :unique, name: Ankole.Plugins.SlackAdapter.ConnectionRegistry},
      {DynamicSupervisor,
       name: Ankole.Plugins.SlackAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
      ConnectionReconciler,
      Channels.StartupSync
    ]
  end

  defp chat_fields do
    [
      field("botToken", "Bot token", "Bot User OAuth Token (xoxb-).", :secret,
        required: true,
        encrypted: true
      ),
      field("appToken", "App token", "App-Level Token (xapp-) with connections:write.", :secret,
        required: true,
        encrypted: true
      ),
      field(
        "platformSubjectNamespace",
        "Platform subject namespace",
        "One namespace per Slack workspace.",
        :string,
        default: "slack-main"
      ),
      field("userName", "Output display name", "Name shown for outbound messages.", :string,
        default: "Slack"
      )
    ]
  end

  defp identity_fields do
    [
      field("clientID", "Client ID", "Slack app Client ID.", :string, required: true),
      field("clientSecret", "Client secret", "Slack app Client Secret.", :secret,
        required: true,
        encrypted: true
      ),
      field("teamID", "Workspace ID", "Optional workspace restriction for login.", :string, []),
      field("botToken", "Bot token", "Directory sync bot token.", :secret, encrypted: true),
      field("appToken", "App token", "Realtime directory event app token.", :secret,
        encrypted: true
      ),
      field("oidc.enabled", "Enable OIDC", "Allow Sign in with Slack.", :boolean, default: true),
      field("oidc.scopes", "OIDC scopes", "Scopes requested during login.", :string_array,
        default: ["openid", "profile", "email"],
        advanced: true
      ),
      field("sync.contacts", "Sync directory", "Import Slack users and usergroups.", :boolean,
        default: true
      ),
      field(
        "sync.websocket",
        "Realtime directory sync",
        "Consume directory events over Socket Mode.",
        :boolean,
        default: true,
        advanced: true
      ),
      field("sync.pageSize", "Sync page size", "users.list cursor page size.", :integer,
        default: 200,
        min: 1,
        max: 200,
        advanced: true
      )
    ]
  end

  defp field(path, label, description, type, opts) do
    {zh_label, zh_description} = Map.fetch!(@zh_fields, path)

    opts
    |> Map.new()
    |> Map.put_new(:advanced, false)
    |> Map.merge(%{
      path: path,
      label: %{"default" => label, "zh-Hans-CN" => zh_label},
      description: %{"default" => description, "zh-Hans-CN" => zh_description},
      type: Atom.to_string(type)
    })
  end
end
