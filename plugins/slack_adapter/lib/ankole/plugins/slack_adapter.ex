defmodule Ankole.Plugins.SlackAdapter do
  @moduledoc "First-party Slack chat and identity-provider plugin."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.SlackAdapter.{Channels, Config, ConnectionReconciler}
  alias Ankole.Plugins.SlackAdapter.{ConnectionSupervisor, IdentityProvider, Inbound, Outbox}
  alias Ankole.Plugins.SlackAdapter.ReplyPreview

  @zh_fields %{
    "botToken" => {"Bot User OAuth Token", "安装应用后在「OAuth & Permissions」中复制，以 xoxb- 开头。"},
    "appToken" =>
      {"App-Level Token",
       "在「Basic Information → App-Level Tokens」中创建，需包含 connections:write 权限并以 xapp- 开头。"},
    "platformSubjectNamespace" => {"平台主体命名空间", "每个 Slack workspace 使用一个命名空间。"},
    "userName" => {"输出显示名", "出站消息使用的显示名称。"},
    "clientID" => {"Client ID", "在 Slack 应用「Basic Information → App Credentials」中获取。"},
    "clientSecret" => {"Client Secret", "与 Client ID 位于同一 App Credentials 页面。"},
    "teamID" => {"Workspace ID", "可选。预先指定登录的 Workspace；留空时由用户选择。"},
    "oidc.enabled" => {"启用登录", "允许管理员使用 Slack 登录。"},
    "oidc.scopes" => {"登录权限范围", "登录时向 Slack 请求的权限，通常无需修改。"},
    "sync.contacts" => {"同步通讯录", "将 Slack 用户和用户组同步到 Ankole。"},
    "sync.websocket" => {"实时同步通讯录变更", "通过 Socket Mode 接收用户和用户组变更；需先开启通讯录同步。"},
    "sync.pageSize" => {"每页同步数量", "每次从 Slack 读取的用户数量，通常保留默认值。"}
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
        adapter_category: "enterprise_im",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Slack"},
        config_key_pattern: "signals_gateway.slack.bindings.<id>",
        config_module: Config,
        fields: chat_fields(),
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        reply_preview_module: ReplyPreview,
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
        default: "slack-main",
        advanced: true
      ),
      field("userName", "Output display name", "Name shown for outbound messages.", :string,
        default: "Slack",
        advanced: true
      )
    ]
  end

  defp identity_fields do
    [
      field(
        "clientID",
        "Client ID",
        "Find it under Basic Information > App Credentials.",
        :string,
        required: true
      ),
      field(
        "clientSecret",
        "Client secret",
        "Find it on the same App Credentials page as the Client ID.",
        :secret,
        required: true,
        encrypted: true
      ),
      field(
        "teamID",
        "Workspace ID",
        "Preselect a workspace during sign-in. Leave blank to let the user choose.",
        :string,
        []
      ),
      field(
        "botToken",
        "Bot User OAuth Token",
        "Token used to sync the directory. It starts with xoxb-.",
        :secret,
        encrypted: true,
        requiredWhen: [required_when("sync.contacts", true)],
        validation:
          pattern_validation(
            "^xoxb-",
            "Enter a Slack Bot Token that starts with xoxb-.",
            "请输入以 xoxb- 开头的 Slack Bot Token。"
          )
      ),
      field(
        "appToken",
        "App-Level Token",
        "Token used for Socket Mode. It needs connections:write and starts with xapp-.",
        :secret,
        encrypted: true,
        requiredWhen: [
          required_when("sync.contacts", true),
          required_when("sync.websocket", true)
        ],
        validation:
          pattern_validation(
            "^xapp-",
            "Enter a Slack App Token that starts with xapp-.",
            "请输入以 xapp- 开头的 Slack App Token。"
          )
      ),
      field(
        "oidc.enabled",
        "Enable sign-in",
        "Allow administrators to sign in with Slack.",
        :boolean,
        default: true
      ),
      field(
        "oidc.scopes",
        "Sign-in scopes",
        "Permissions requested during sign-in. Usually keep the default.",
        :string_array,
        default: ["openid", "profile", "email"],
        advanced: true
      ),
      field(
        "sync.contacts",
        "Sync directory",
        "Import Slack users and user groups into Ankole.",
        :boolean,
        default: true
      ),
      field(
        "sync.websocket",
        "Sync directory changes",
        "Receive user and user-group changes through Socket Mode. Requires directory sync.",
        :boolean,
        default: true,
        advanced: true
      ),
      field(
        "sync.pageSize",
        "Records per page",
        "Number of users requested from Slack per page. Usually keep the default.",
        :integer,
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

  defp required_when(path, value), do: %{path: path, value: value}

  defp pattern_validation(pattern, message, zh_message) do
    %{
      kind: "pattern",
      pattern: pattern,
      message: %{"default" => message, "zh-Hans-CN" => zh_message}
    }
  end
end
