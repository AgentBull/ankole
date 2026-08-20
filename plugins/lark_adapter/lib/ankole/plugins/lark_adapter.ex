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

  @impl true
  def plugin_id, do: "lark-adapter"

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
    # Signal and identity contracts have separate host-owned lifecycles.
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "lark",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "signals_gateway.lark.binding_configs.<id>",
        config_module: Config,
        worker_env_module: RuntimeEnv,
        fields: chat_fields(),
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        reply_preview_module: CardKit,
        connection_supervisor: ConnectionSupervisor,
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
          "card"
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
      }
    ]
  end

  @impl true
  def children do
    # Shared plugin processes start once and use provider app config as runtime keys.
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
        "platformSubjectNamespace",
        %{"default" => "Platform subject namespace", "zh-Hans-CN" => "平台主体命名空间"},
        %{
          "default" => "Namespace used when mapping provider users into Ankole subjects.",
          "zh-Hans-CN" => "映射 provider 用户到 Ankole 主体时使用的命名空间。"
        },
        :string,
        default: "lark-main",
        advanced: true
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
      field(
        "domain",
        %{"default" => "Service region", "zh-Hans-CN" => "服务区域"},
        %{
          "default" => "Select the platform where the app was created.",
          "zh-Hans-CN" => "选择创建该应用时使用的开放平台。"
        },
        :select,
        default: "feishu",
        options: [
          option("feishu", %{
            "default" => "Feishu (Mainland China)",
            "zh-Hans-CN" => "飞书（中国大陆）"
          }),
          option("lark", %{"default" => "Lark (Global)", "zh-Hans-CN" => "Lark（海外）"})
        ]
      ),
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
