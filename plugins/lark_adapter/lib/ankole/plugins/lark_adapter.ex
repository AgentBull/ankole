defmodule Ankole.Plugins.LarkAdapter do
  @impl true
  def activation, do: :always

  @moduledoc """
  First-party Lark / Feishu plugin declaration.
  """

  @behaviour Ankole.Plugins.Plugin

  import Ankole.Plugins.Spec, only: [field: 5]

  alias Ankole.Plugins.LarkAdapter.BotIdentity
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.IMGroups
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Plugins.LarkAdapter.Delivery
  alias Ankole.Plugins.LarkAdapter.CardKit

  # Chat bindings, identity providers, and connector connections choose from the same platforms.
  @domain_label %{"default" => "Service region", "zh-Hans-CN" => "服务区域"}
  @domain_options [
    %{
      value: "feishu",
      label: %{"default" => "Feishu (Mainland China)", "zh-Hans-CN" => "飞书（中国大陆）"}
    },
    %{value: "lark", label: %{"default" => "Lark (Global)", "zh-Hans-CN" => "Lark（海外）"}}
  ]

  @impl true
  def plugin_id, do: "lark-adapter"

  @impl true
  def display_name do
    %{
      "default" => "Feishu / Lark Adapter",
      "zh-Hans-CN" => "飞书 / Lark 适配器"
    }
  end

  @impl true
  def description do
    %{
      "default" =>
        "Connects Feishu or Lark self-built apps as a signals provider and login provider.",
      "zh-Hans-CN" => "连接飞书或 Lark 自建应用，作为信号提供方与登录提供方。"
    }
  end

  @impl true
  def app_config_definitions, do: Config.app_config_definitions()

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    # Signal and identity contracts have separate host-owned lifecycles.
    [
      %{
        contract_id: "signals.adapter",
        id: "lark",
        adapter_category: "enterprise_im",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "signals.lark.binding_configs.<id>",
        config_module: Config,
        application_bindings: :one,
        fields: chat_fields(),
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        observe_module: Inbound,
        deliver_module: Delivery,
        preview_module: CardKit,
        binding_saved_module: IMGroups,
        author_hydrator: IdentityProvider,
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
          "card",
          "form",
          "action_notice"
        ]
      },
      %{
        contract_id: "principals.identity_provider",
        id: "lark",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "principals.identity_providers.lark.<id>",
        fields: identity_fields(),
        module: IdentityProvider,
        connection_reconciler: ConnectionReconciler,
        capabilities: [
          "oidc_authorization",
          "oidc_code_exchange",
          "directory_full_sync",
          "directory_realtime_sync"
        ]
      },
      %{
        contract_id: "connectors.connector",
        id: "lark",
        plugin_id: plugin_id(),
        module: Ankole.Plugins.LarkAdapter.Connector,
        display_name: adapter_display_name(),
        public_fields: [
          %{
            key: "domain",
            label: @domain_label,
            type: "select",
            default: "feishu",
            options: @domain_options
          },
          %{key: "identityProvider", label: "Employee identity provider", required: false}
        ],
        event_streams: [
          %{
            id: "lark",
            label: "Business events",
            event_types:
              Ankole.Plugins.LarkAdapter.ConnectorEvents.event_types() ++ ["card.action.trigger"]
          }
        ],
        trigger_types: [
          %{
            id: "lark_approval",
            label: "Approval definition",
            scope_label: "Approval code",
            requires_personal_account: false
          },
          %{
            id: "lark_calendar",
            label: "Personal calendar",
            scope_label: "Calendar ID",
            requires_personal_account: true,
            oauth_scopes: ["calendar:calendar.event:read"]
          }
        ]
      }
    ]
  end

  @impl true
  def children do
    # Shared plugin processes start once and use provider app config as runtime keys.
    [
      Ankole.Plugins.ConnectionLifecycle.supervisor_spec(__MODULE__, [
        FeishuOpenAPI.Supervisor,
        {Registry, keys: :unique, name: Ankole.Plugins.LarkAdapter.ConnectionRegistry},
        {DynamicSupervisor,
         name: Ankole.Plugins.LarkAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
        BotIdentity,
        ConnectionReconciler,
        {Ankole.Plugins.ChannelSync,
         adapter: "lark", worker: Ankole.Plugins.LarkAdapter.Jobs.SyncIMGroups}
      ])
    ]
  end

  defp adapter_display_name do
    %{
      "default" => "Feishu / Lark",
      "zh-Hans-CN" => "飞书 / Lark"
    }
  end

  defp domain_field do
    field(
      "domain",
      @domain_label,
      %{
        "default" => "Select the platform where the app was created.",
        "zh-Hans-CN" => "选择创建该应用时使用的开放平台。"
      },
      :select,
      default: "feishu",
      options: @domain_options
    )
  end

  defp chat_fields do
    [
      field(
        "appID",
        %{"default" => "App ID", "zh-Hans-CN" => "应用 ID"},
        %{"default" => "Self-built app identifier.", "zh-Hans-CN" => "自建应用的 App ID。"},
        :string,
        required: true
      ),
      field(
        "appSecret",
        %{"default" => "App Secret", "zh-Hans-CN" => "应用密钥"},
        %{"default" => "Self-built app secret.", "zh-Hans-CN" => "自建应用的 App Secret。"},
        :secret,
        required: true,
        encrypted: true
      ),
      domain_field(),
      field(
        "identityProvider",
        %{"default" => "Identity provider", "zh-Hans-CN" => "身份源提供商"},
        %{
          "default" =>
            "Identity provider whose users the senders of this binding resolve to. A single provider is adopted by default; choose one when several exist.",
          "zh-Hans-CN" => "此绑定的发信人解析到哪个身份源的用户。只有一个身份源时默认采用；有多个时必须选择。"
        },
        :identity_provider,
        identity_provider_adapter: "lark"
      ),
      field(
        "userName",
        %{"default" => "Output display name", "zh-Hans-CN" => "输出显示名"},
        %{
          "default" => "Name shown for outbound provider messages.",
          "zh-Hans-CN" => "发送 provider 消息时显示的名称。"
        },
        :string,
        default: "Lark / Feishu",
        advanced: true
      )
    ]
  end

  defp identity_fields do
    [
      field(
        "appID",
        %{"default" => "App ID", "zh-Hans-CN" => "App ID"},
        %{
          "default" => "Find it under Basic information > Credentials in the developer console.",
          "zh-Hans-CN" => "在开发者后台「基础信息 → 凭证与基础信息」中获取。"
        },
        :string,
        required: true
      ),
      field(
        "appSecret",
        %{"default" => "App Secret", "zh-Hans-CN" => "App Secret"},
        %{
          "default" => "Find it on the same credentials page as the App ID.",
          "zh-Hans-CN" => "与 App ID 位于同一“凭证与基础信息”页面。"
        },
        :secret,
        required: true,
        encrypted: true
      ),
      domain_field(),
      field(
        "oidc.enabled",
        %{"default" => "Enable sign-in", "zh-Hans-CN" => "启用登录"},
        %{
          "default" => "Allow administrators to sign in with Feishu or Lark.",
          "zh-Hans-CN" => "允许管理员使用飞书或 Lark 登录。"
        },
        :boolean,
        default: true
      ),
      field(
        "oidc.scopes",
        %{"default" => "Sign-in scopes", "zh-Hans-CN" => "登录权限范围"},
        %{
          "default" => "Permissions requested during sign-in. Usually keep the default.",
          "zh-Hans-CN" => "登录时向飞书或 Lark 请求的权限，通常无需修改。"
        },
        :string_array,
        default: ["contact:user.employee_id:readonly"],
        advanced: true
      ),
      field(
        "oidc.requestPersonalConnectorScopes",
        %{"default" => "Connect personal tools at sign-in", "zh-Hans-CN" => "登录时授权个人工具"},
        %{
          "default" =>
            "Request personal tasks, calendar, and approval access in the same consent screen.",
          "zh-Hans-CN" => "在同一授权页面请求个人任务、日历和审批权限。"
        },
        :boolean,
        default: false
      ),
      field(
        "oidc.personalConnectorScopes",
        %{"default" => "Personal tool scopes", "zh-Hans-CN" => "个人工具权限范围"},
        %{
          "default" =>
            "Request only permissions enabled for this application in the developer console.",
          "zh-Hans-CN" => "填写开发者后台已为该应用开通的权限。"
        },
        :string_array,
        default: [
          "offline_access",
          "task:task:write",
          "task:tasklist:write",
          "task:comment:write",
          "task:section:write",
          "calendar:calendar",
          "approval:approval"
        ],
        advanced: true
      ),
      field(
        "sync.contacts",
        %{"default" => "Sync directory", "zh-Hans-CN" => "同步通讯录"},
        %{
          "default" => "Import Feishu or Lark users, departments, and memberships into Ankole.",
          "zh-Hans-CN" => "将飞书或 Lark 用户、部门和成员关系同步到 Ankole。"
        },
        :boolean,
        default: true,
        advanced: true
      ),
      field(
        "sync.websocket",
        %{"default" => "Sync directory changes", "zh-Hans-CN" => "实时同步通讯录变更"},
        %{
          "default" =>
            "Receive user and department changes over a long connection. Requires directory sync.",
          "zh-Hans-CN" => "通过长连接接收用户和部门变更；需先开启通讯录同步。"
        },
        :boolean,
        default: true,
        advanced: true
      ),
      field(
        "sync.admissionScope",
        %{"default" => "Admission scope", "zh-Hans-CN" => "人员准入范围"},
        %{
          "default" =>
            "Use the contact scope only when it defines who may use Ankole. Review the first complete snapshot before automatic removal.",
          "zh-Hans-CN" => "仅在通讯录范围代表 Ankole 准入范围时启用。自动移除缺员前必须审核首个完整快照。"
        },
        :select,
        default: "none",
        options: [
          option("none", %{
            "default" => "Do not infer removal from absence",
            "zh-Hans-CN" => "不根据缺员推断停用"
          }),
          option("contact", %{"default" => "Reviewed contact scope", "zh-Hans-CN" => "经审核的通讯录范围"})
        ],
        advanced: true
      ),
      field(
        "sync.maximumRemovalPercent",
        %{"default" => "Maximum automatic reduction (%)", "zh-Hans-CN" => "自动处理的最大缩减比例（%）"},
        %{
          "default" =>
            "A larger reduction requires review. An empty directory always requires review.",
          "zh-Hans-CN" => "超过此比例的缩减需要审核。空目录始终需要审核。"
        },
        :integer,
        default: 20,
        min: 1,
        max: 100,
        advanced: true
      ),
      field(
        "sync.pageSize",
        %{"default" => "Records per page", "zh-Hans-CN" => "每页同步数量"},
        %{
          "default" => "Number of records requested per page. Usually keep the default.",
          "zh-Hans-CN" => "每次读取的记录数量，通常保留默认值。"
        },
        :integer,
        default: 50,
        min: 1,
        max: 50,
        advanced: true
      )
    ]
  end

  defp option(value, label), do: %{value: value, label: label}
end
