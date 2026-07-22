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
    "tenantID" => {"租户 ID", "Entra 租户 GUID；单租户应用必填。"},
    "platformSubjectNamespace" => {"平台主体命名空间", "与 Entra IdP 实例共享的主体命名空间。"},
    "userName" => {"输出显示名", "出站消息使用的显示名称。"},
    "clientID" => {"Client ID", "Entra 应用注册的 Application (client) ID。"},
    "clientSecret" => {"Client Secret", "Entra 应用的客户端密码。"},
    "oidc.enabled" => {"启用 OIDC", "允许使用 Entra ID 登录。"},
    "oidc.scopes" => {"OIDC 权限范围", "登录时请求的 scope。"},
    "sync.contacts" => {"同步目录", "导入 Entra 用户与组。"},
    "sync.realtime" => {"实时目录同步", "通过 Graph change notifications 接收目录变更。"},
    "sync.pageSize" => {"同步分页大小", "Graph 列表接口的 $top 分页大小。"},
    "sync.groupsFilter" => {"组过滤器", "可选，OData $filter 限定要同步的组。"},
    "sync.includeGuests" => {"包含来宾", "目录同步是否包含 Guest 用户。"},
    "publicBaseURL" => {"公网基础 URL", "本安装的公网 HTTPS 地址，用于拼 Graph 通知端点。"}
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
        default: Config.default_namespace()
      ),
      field("userName", "Output display name", "Name shown for outbound messages.", :string,
        default: "Teams"
      )
    ]
  end

  defp identity_fields do
    [
      field("tenantID", "Tenant ID", "Entra tenant GUID.", :string, required: true),
      field("clientID", "Client ID", "Entra app registration Application (client) ID.", :string,
        required: true
      ),
      field("clientSecret", "Client secret", "Entra app client secret.", :secret,
        required: true,
        encrypted: true
      ),
      field("oidc.enabled", "Enable OIDC", "Allow sign-in with Entra ID.", :boolean,
        default: true
      ),
      field("oidc.scopes", "OIDC scopes", "Scopes requested during login.", :string_array,
        default: ["openid", "profile", "email", "User.Read"],
        advanced: true
      ),
      field("sync.contacts", "Sync directory", "Import Entra users and groups.", :boolean,
        default: true
      ),
      field(
        "sync.realtime",
        "Realtime directory sync",
        "Receive directory changes through Graph change notifications.",
        :boolean,
        default: true,
        advanced: true
      ),
      field("sync.pageSize", "Sync page size", "Graph $top page size for list calls.", :integer,
        default: 999,
        min: 1,
        max: 999,
        advanced: true
      ),
      field(
        "sync.groupsFilter",
        "Groups filter",
        "Optional OData $filter restricting synced groups.",
        :string,
        advanced: true
      ),
      field(
        "sync.includeGuests",
        "Include guests",
        "Whether directory sync includes Guest users.",
        :boolean,
        default: false,
        advanced: true
      ),
      field(
        "publicBaseURL",
        "Public base URL",
        "Public HTTPS address of this installation, used to build the Graph notification endpoint.",
        :string,
        []
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
end
