defmodule Ankole.Plugins.Microsoft365Adapter do
  @moduledoc "First-party Microsoft 365 chat (Teams) and identity (Entra ID) plugin."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.Microsoft365Adapter.{Config, Inbound, Outbox, TeamsChannels, TeamsWebhook}

  alias Ankole.Plugins.Microsoft365Adapter.{
    DirectoryWebhook,
    IdentityProvider,
    SubscriptionReconciler
  }

  @zh_fields %{
    "appID" => {"应用 ID", "Azure Bot 注册的 Microsoft App ID（client id）。"},
    "appPassword" => {"应用密码", "Microsoft App 的 client secret。"},
    "botTenancy" => {"应用租户模式", "Azure Bot 应用类型：单租户或多租户。"},
    "tenantID" => {"目录（租户）ID", "在 Entra 应用注册的“概述”页面复制。"},
    "platformSubjectNamespace" => {"平台主体命名空间", "与 Entra IdP 实例共享的主体命名空间。"},
    "userName" => {"输出显示名", "出站消息使用的显示名称。"},
    "clientID" => {"应用程序（客户端）ID", "在 Entra 应用注册的“概述”页面复制。"},
    "clientSecret" => {"客户端密码值", "创建客户端密码后复制“值”，不要填写“密码 ID”。"},
    "oidc.enabled" => {"启用登录", "允许管理员使用 Entra ID 登录。"},
    "oidc.scopes" => {"登录权限范围", "登录时向 Microsoft 请求的权限，通常无需修改。"},
    "sync.contacts" => {"同步通讯录", "将 Entra ID 用户和组同步到 Ankole。"},
    "sync.realtime" => {"实时同步通讯录变更", "通过 Microsoft Graph 接收用户和组变更；需要 Ankole 公网 HTTPS 地址。"},
    "sync.pageSize" => {"每页同步数量", "每次从 Microsoft Graph 读取的记录数量，通常保留默认值。"},
    "sync.groupsFilter" => {"同步组筛选条件", "可选。填写 Microsoft Graph OData $filter；留空则同步全部组。"},
    "sync.includeGuests" => {"包含来宾用户", "同步时包含 Entra ID 来宾用户。"},
    "publicBaseURL" => {"Ankole 公网地址", "用于接收 Microsoft Graph 变更通知的 Ankole 公网 HTTPS 地址。"}
  }

  @impl true
  def plugin_id, do: "microsoft365-adapter"

  @impl true
  def display_name,
    do: %{"default" => "Microsoft 365 Adapter", "zh-Hans-CN" => "Microsoft 365 适配器"}

  @impl true
  def description do
    %{
      "default" =>
        "Connects Microsoft Teams as a signals provider and Entra ID as a login provider.",
      "zh-Hans-CN" => "连接 Microsoft Teams 作为信号提供方、Entra ID 作为登录提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "teams",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Microsoft Teams"},
        config_key_pattern: "signals_gateway.teams.bindings.<id>",
        config_module: Config,
        fields: chat_fields(),
        # observe_all / may_intervene require the Teams app manifest to grant
        # RSC read permissions (ChannelMessage.Read.Group, ChatMessage.Read.Chat);
        # without them Teams only delivers @bot messages in group contexts.
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        binding_saved_module: TeamsChannels,
        inbound_capabilities: [
          "entry_receive",
          "entry_removed",
          "reaction_add",
          "reaction_remove",
          "action_event"
        ],
        # No add_reaction/remove_reaction (Bot Framework cannot send message
        # reactions) and no outbound_reconciliation (the connector has no
        # read-back API, so interrupted sends stay unknown_after_send).
        outbound_capabilities: [
          "post_entry",
          "reply_entry",
          "edit_entry",
          "delete_entry",
          "divider",
          "card"
        ]
      },
      %{
        contract_id: "signals_gateway.webhook_handler",
        id: "teams",
        plugin_id: plugin_id(),
        module: TeamsWebhook,
        kinds: ["messages"]
      },
      %{
        contract_id: "principals.identity_provider",
        id: "entra-id",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Entra ID", "zh-Hans-CN" => "Entra ID"},
        config_key_pattern: "principals.identity_providers.entra-id.<id>",
        fields: identity_fields(),
        module: IdentityProvider,
        connection_reconciler: SubscriptionReconciler,
        capabilities: [
          "oidc_authorization",
          "oidc_code_exchange",
          "directory_full_sync",
          "directory_realtime_sync"
        ]
      },
      %{
        contract_id: "signals_gateway.webhook_handler",
        id: "entra-id",
        plugin_id: plugin_id(),
        module: DirectoryWebhook,
        kinds: ["directory"]
      }
    ]
  end

  @impl true
  def children do
    [TeamsChannels.StartupSync, SubscriptionReconciler]
  end

  defp chat_fields do
    [
      field("appID", "App ID", "Azure Bot registration Microsoft App ID (client id).", :string,
        required: true
      ),
      field("appPassword", "App password", "Microsoft App client secret.", :secret,
        required: true,
        encrypted: true
      ),
      field(
        "botTenancy",
        "App tenancy",
        "Azure Bot app type: single-tenant or multi-tenant.",
        :select,
        default: "single_tenant",
        options: [
          option("single_tenant", %{"default" => "Single tenant", "zh-Hans-CN" => "单租户"}),
          option("multi_tenant", %{"default" => "Multi tenant", "zh-Hans-CN" => "多租户"})
        ]
      ),
      field(
        "tenantID",
        "Tenant ID",
        "Entra tenant GUID; required for single-tenant apps.",
        :string,
        []
      ),
      field(
        "platformSubjectNamespace",
        "Platform subject namespace",
        "Subject namespace shared with the Entra ID identity provider instance.",
        :string,
        default: Config.default_namespace(),
        advanced: true
      ),
      field("userName", "Output display name", "Name shown for outbound messages.", :string,
        default: "Teams",
        advanced: true
      )
    ]
  end

  defp identity_fields do
    [
      field(
        "tenantID",
        "Directory (tenant) ID",
        "Copy it from the Entra app registration Overview page.",
        :string,
        required: true,
        validation:
          pattern_validation(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
            "Enter a Directory (tenant) ID in GUID format.",
            "请输入 GUID 格式的目录（租户）ID。"
          )
      ),
      field(
        "clientID",
        "Application (client) ID",
        "Copy it from the Entra app registration Overview page.",
        :string,
        required: true
      ),
      field(
        "clientSecret",
        "Client secret value",
        "Copy the secret Value, not the Secret ID.",
        :secret,
        required: true,
        encrypted: true
      ),
      field(
        "oidc.enabled",
        "Enable sign-in",
        "Allow administrators to sign in with Entra ID.",
        :boolean,
        default: true
      ),
      field(
        "oidc.scopes",
        "Sign-in scopes",
        "Permissions requested during sign-in. Usually keep the default.",
        :string_array,
        default: ["openid", "profile", "email", "User.Read"],
        advanced: true
      ),
      field(
        "sync.contacts",
        "Sync directory",
        "Import Entra ID users and groups into Ankole.",
        :boolean,
        default: true
      ),
      field(
        "sync.realtime",
        "Sync directory changes",
        "Receive user and group changes through Microsoft Graph. Requires a public HTTPS URL for Ankole.",
        :boolean,
        default: true,
        advanced: true
      ),
      field(
        "sync.pageSize",
        "Records per page",
        "Number of records requested from Microsoft Graph per page. Usually keep the default.",
        :integer,
        default: 999,
        min: 1,
        max: 999,
        advanced: true
      ),
      field(
        "sync.groupsFilter",
        "Synced groups filter",
        "Optional Microsoft Graph OData $filter. Leave blank to sync all groups.",
        :string,
        advanced: true
      ),
      field(
        "sync.includeGuests",
        "Include guest users",
        "Include Entra ID guest users in directory sync.",
        :boolean,
        default: false,
        advanced: true
      ),
      field(
        "publicBaseURL",
        "Ankole public URL",
        "Public HTTPS URL for Ankole to receive Microsoft Graph change notifications.",
        :string,
        requiredWhen: [
          required_when("sync.contacts", true),
          required_when("sync.realtime", true)
        ]
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

  defp option(value, label), do: %{value: value, label: label}
  defp required_when(path, value), do: %{path: path, value: value}

  defp pattern_validation(pattern, message, zh_message) do
    %{
      kind: "pattern",
      pattern: pattern,
      message: %{"default" => message, "zh-Hans-CN" => zh_message}
    }
  end
end
