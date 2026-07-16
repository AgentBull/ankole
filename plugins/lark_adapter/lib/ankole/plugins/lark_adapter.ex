defmodule Ankole.Plugins.LarkAdapter do
  @moduledoc """
  First-party Lark / Feishu plugin declaration.
  """

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.IMGroups
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Plugins.LarkAdapter.Outbox
  alias Ankole.Plugins.LarkAdapter.CardKit
  alias Ankole.Plugins.LarkAdapter.RuntimeEnv
  alias Ankole.Plugins.LarkAdapter.SkillEnablement

  @impl true
  def plugin_id, do: "lark-adapter"

  @impl true
  def api_version, do: 1

  @impl true
  def display_name do
    %{
      "default" => "Lark Adapter",
      "zh-Hans-CN" => "飞书适配器"
    }
  end

  @impl true
  def description do
    %{
      "default" => "Connects Lark self-built apps as a signals provider and login provider.",
      "zh-Hans-CN" => "连接飞书自建应用作为信号提供方与登录提供方。"
    }
  end

  @impl true
  def app_config_definitions, do: Config.app_config_definitions()

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    # The plugin exposes separate signal, Skill, and identity contracts because
    # each host subsystem owns a different lifecycle and projection.
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "lark",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "signals_gateway.lark.bindings.<agent_uid>",
        config_module: Config,
        worker_env_module: RuntimeEnv,
        fields: chat_fields(),
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        reply_preview_module: CardKit,
        connection_supervisor: ConnectionSupervisor,
        binding_saved_module: IMGroups,
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
        contract_id: "ai_agent.library.skill_enablement_provider",
        id: "lark-cli-bot",
        plugin_id: plugin_id(),
        module: SkillEnablement
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
      }
    ]
  end

  @impl true
  def children do
    # Long-connection processes are installed globally for the plugin, then
    # keyed by provider app config at runtime.
    [
      {Registry, keys: :unique, name: Ankole.Plugins.LarkAdapter.ConnectionRegistry},
      {DynamicSupervisor,
       name: Ankole.Plugins.LarkAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
      ConnectionReconciler,
      IMGroups.StartupSync
    ]
  end

  defp adapter_display_name do
    %{
      "default" => "Lark",
      "zh-Hans-CN" => "飞书"
    }
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
      field(
        "domain",
        %{"default" => "Domain", "zh-Hans-CN" => "域"},
        %{"default" => "Provider network to call.", "zh-Hans-CN" => "要连接的服务网络。"},
        :select,
        default: "feishu",
        options: [
          option("feishu", %{"default" => "Feishu.cn", "zh-Hans-CN" => "Feishu.cn"}),
          option("lark", %{"default" => "Larksuite.com", "zh-Hans-CN" => "Larksuite.com"})
        ]
      ),
      field(
        "baseURL",
        %{"default" => "Base URL", "zh-Hans-CN" => "基础 URL"},
        %{
          "default" => "Optional override for local provider-compatible testing.",
          "zh-Hans-CN" => "可选，本地或兼容服务测试时覆盖 provider URL。"
        },
        :string,
        []
      ),
      field(
        "platformSubjectNamespace",
        %{"default" => "Platform subject namespace", "zh-Hans-CN" => "平台主体命名空间"},
        %{
          "default" => "Namespace used when mapping provider users into Ankole subjects.",
          "zh-Hans-CN" => "映射 provider 用户到 Ankole 主体时使用的命名空间。"
        },
        :string,
        default: "lark-main"
      ),
      field(
        "userName",
        %{"default" => "Output display name", "zh-Hans-CN" => "输出显示名"},
        %{
          "default" => "Name shown for outbound provider messages.",
          "zh-Hans-CN" => "发送 provider 消息时显示的名称。"
        },
        :string,
        default: "Lark / Feishu"
      )
    ]
  end

  defp identity_fields do
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
      field(
        "domain",
        %{"default" => "Domain", "zh-Hans-CN" => "域"},
        %{"default" => "Provider network to call.", "zh-Hans-CN" => "要连接的服务网络。"},
        :select,
        default: "feishu",
        options: [
          option("feishu", %{"default" => "Feishu", "zh-Hans-CN" => "飞书"}),
          option("lark", %{"default" => "Lark", "zh-Hans-CN" => "Lark"})
        ]
      ),
      field(
        "oidc.enabled",
        %{"default" => "Enable OIDC", "zh-Hans-CN" => "启用 OIDC"},
        %{
          "default" => "Allows operators to sign in through this provider.",
          "zh-Hans-CN" => "允许管理员通过该身份提供方登录。"
        },
        :boolean,
        default: true
      ),
      field(
        "oidc.scopes",
        %{"default" => "OIDC scopes", "zh-Hans-CN" => "OIDC 权限范围"},
        %{
          "default" => "Scopes requested during OIDC authorization.",
          "zh-Hans-CN" => "OIDC 授权时请求的 scope。"
        },
        :string_array,
        default: ["contact:user.employee_id:readonly"],
        advanced: true
      ),
      field(
        "sync.contacts",
        %{"default" => "Sync directory", "zh-Hans-CN" => "同步通讯录"},
        %{
          "default" =>
            "Imports provider contacts into Principals, department groups, and memberships.",
          "zh-Hans-CN" => "将 provider 通讯录导入 Principals、部门组和成员关系。"
        },
        :boolean,
        default: true
      ),
      field(
        "sync.websocket",
        %{"default" => "Incremental contact sync", "zh-Hans-CN" => "增量通讯录同步"},
        %{
          "default" => "Consumes provider contact-change events when directory sync is enabled.",
          "zh-Hans-CN" => "通讯录同步开启时，通过长连接消费 provider 通讯录变更事件。"
        },
        :boolean,
        default: true,
        advanced: true
      ),
      field(
        "sync.pageSize",
        %{"default" => "Sync page size", "zh-Hans-CN" => "同步分页大小"},
        %{
          "default" => "Provider page size for full directory sync.",
          "zh-Hans-CN" => "全量通讯录同步时使用的 provider 分页大小。"
        },
        :integer,
        default: 50,
        min: 1,
        max: 50,
        advanced: true
      )
    ]
  end

  defp field(path, label, description, type, opts) do
    opts
    |> Map.new()
    |> Map.put_new(:advanced, false)
    |> Map.merge(%{
      path: path,
      label: label,
      description: description,
      type: Atom.to_string(type)
    })
  end

  defp option(value, label), do: %{value: value, label: label}
end
