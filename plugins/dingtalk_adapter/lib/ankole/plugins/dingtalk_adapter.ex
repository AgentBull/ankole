defmodule Ankole.Plugins.DingTalkAdapter do
  @moduledoc """
  First-party DingTalk (钉钉) plugin declaration.

  DingTalk is both a SignalsGateway chat adapter and a Principals login/identity
  provider over one Stream long connection. The capability face is trimmed to
  what the DingTalk robot API actually offers: group messages are delivered only
  when the bot is @-mentioned or DMed (`addressed_only`), there are no
  reaction/edit/recall inbound events, and outbound has no anchored reply, edit,
  reaction, divider, or reconciliation.
  """

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.DingTalkAdapter.AICard
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.ConnectionReconciler
  alias Ankole.Plugins.DingTalkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.DingTalkAdapter.IdentityProvider
  alias Ankole.Plugins.DingTalkAdapter.Inbound
  alias Ankole.Plugins.DingTalkAdapter.Outbox

  @impl true
  def plugin_id, do: "dingtalk-adapter"

  @impl true
  def display_name do
    %{"default" => "DingTalk Adapter", "zh-Hans-CN" => "钉钉适配器"}
  end

  @impl true
  def description do
    %{
      "default" => "Connects DingTalk enterprise apps as a signals provider and login provider.",
      "zh-Hans-CN" => "连接钉钉企业内部应用作为信号提供方与登录提供方。"
    }
  end

  @impl true
  def app_config_definitions, do: Config.app_config_definitions()

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "dingtalk",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "signals_gateway.dingtalk.bindings.<agent_uid>",
        config_module: Config,
        fields: chat_fields(),
        supported_group_message_modes: ["addressed_only"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        reply_preview_module: AICard,
        connection_supervisor: ConnectionSupervisor,
        inbound_capabilities: ["entry_receive", "action_event"],
        outbound_capabilities: ["post_entry", "delete_entry", "card"]
      },
      %{
        contract_id: "principals.identity_provider",
        id: "dingtalk",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "principals.identity_providers.dingtalk.<id>",
        fields: identity_fields(),
        module: IdentityProvider,
        connection_reconciler: ConnectionReconciler,
        capabilities: [
          "oidc_authorization",
          "oidc_code_exchange",
          "credential_check",
          "directory_full_sync",
          "directory_realtime_sync"
        ]
      }
    ]
  end

  @impl true
  def children do
    [
      {Registry, keys: :unique, name: Ankole.Plugins.DingTalkAdapter.ConnectionRegistry},
      {DynamicSupervisor,
       name: Ankole.Plugins.DingTalkAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
      ConnectionReconciler
    ]
  end

  defp adapter_display_name do
    %{"default" => "DingTalk", "zh-Hans-CN" => "钉钉"}
  end

  defp chat_fields do
    [
      field(
        "clientId",
        %{"default" => "Client ID (AppKey)", "zh-Hans-CN" => "应用 Client ID（AppKey）"},
        %{
          "default" =>
            "Enterprise-internal app Client ID from Basic information > Credentials (also the Stream clientId).",
          "zh-Hans-CN" => "企业内部应用的 Client ID，在开发者后台「基础信息 → 凭证与基础信息」查看（同时作为 Stream clientId）。"
        },
        :string,
        required: true
      ),
      field(
        "clientSecret",
        %{
          "default" => "Client Secret (AppSecret)",
          "zh-Hans-CN" => "应用 Client Secret（AppSecret）"
        },
        %{
          "default" => "Enterprise-internal app Client Secret from the same page.",
          "zh-Hans-CN" => "企业内部应用的 Client Secret，与 Client ID 在同一页面。"
        },
        :secret,
        required: true,
        encrypted: true
      ),
      field(
        "robotCode",
        %{"default" => "Robot code", "zh-Hans-CN" => "机器人编码"},
        %{
          "default" => "Robot code; defaults to the AppKey for enterprise-internal robots.",
          "zh-Hans-CN" => "机器人编码；企业内部应用机器人默认与 AppKey 相同，仅特例需要覆盖。"
        },
        :string,
        []
      ),
      field(
        "cardTemplateId",
        %{"default" => "AI card template id", "zh-Hans-CN" => "AI 卡片模板 id"},
        %{
          "default" =>
            "AI card template id from the card platform; empty degrades AI replies to plain Markdown.",
          "zh-Hans-CN" => "卡片平台的 AI 卡片模板 id；为空时 AI 回复降级为纯 Markdown 消息。"
        },
        :string,
        []
      ),
      field(
        "group_message_mode",
        %{"default" => "Group message mode", "zh-Hans-CN" => "群消息模式"},
        %{
          "default" => "DingTalk only delivers @-mention and DM messages to robots.",
          "zh-Hans-CN" => "钉钉仅将 @ 机器人与单聊消息投递给机器人。"
        },
        :select,
        default: "addressed_only",
        options: [
          option("addressed_only", %{
            "default" => "Addressed only",
            "zh-Hans-CN" => "仅被 @ 或单聊"
          })
        ]
      ),
      field(
        "platformSubjectNamespace",
        %{"default" => "Platform subject namespace", "zh-Hans-CN" => "平台主体命名空间"},
        %{
          "default" => "Namespace used when mapping DingTalk users into Ankole subjects.",
          "zh-Hans-CN" => "映射钉钉用户到 Ankole 主体时使用的命名空间。"
        },
        :string,
        default: "dingtalk-main"
      ),
      field(
        "userName",
        %{"default" => "Output display name", "zh-Hans-CN" => "输出显示名"},
        %{
          "default" => "Name shown for outbound provider messages.",
          "zh-Hans-CN" => "发送 provider 消息时显示的名称。"
        },
        :string,
        default: "钉钉 / DingTalk"
      )
    ]
  end

  defp identity_fields do
    [
      field(
        "clientId",
        %{"default" => "Client ID (AppKey)", "zh-Hans-CN" => "Client ID（原 AppKey）"},
        %{
          "default" =>
            "Find it under Basic information > Credentials in DingTalk Developer Console.",
          "zh-Hans-CN" => "在钉钉开发者后台「基础信息 → 凭证与基础信息」中获取。"
        },
        :string,
        required: true
      ),
      field(
        "clientSecret",
        %{
          "default" => "Client Secret (AppSecret)",
          "zh-Hans-CN" => "Client Secret（原 AppSecret）"
        },
        %{
          "default" => "Find it on the same credentials page as the Client ID.",
          "zh-Hans-CN" => "与 Client ID 位于同一“凭证与基础信息”页面。"
        },
        :secret,
        required: true,
        encrypted: true
      ),
      field(
        "oidc.enabled",
        %{"default" => "Enable sign-in", "zh-Hans-CN" => "启用登录"},
        %{
          "default" => "Allow administrators to sign in with DingTalk.",
          "zh-Hans-CN" => "允许管理员使用钉钉登录。"
        },
        :boolean,
        default: true
      ),
      field(
        "oidc.scope",
        %{"default" => "Sign-in scopes", "zh-Hans-CN" => "登录权限范围"},
        %{
          "default" =>
            "openid identifies the user. corpid also returns the selected organization ID. Usually keep the default.",
          "zh-Hans-CN" => "openid 用于识别用户；corpid 还会返回所选组织 ID。通常无需修改。"
        },
        :select,
        default: "openid corpid",
        options: [
          option("openid", %{"default" => "openid", "zh-Hans-CN" => "openid"}),
          option("openid corpid", %{"default" => "openid corpid", "zh-Hans-CN" => "openid corpid"})
        ],
        advanced: true
      ),
      field(
        "sync.contacts",
        %{"default" => "Sync directory", "zh-Hans-CN" => "同步通讯录"},
        %{
          "default" => "Import DingTalk users, departments, and memberships into Ankole.",
          "zh-Hans-CN" => "将钉钉用户、部门和成员关系同步到 Ankole。"
        },
        :boolean,
        default: true
      ),
      field(
        "sync.websocket",
        %{"default" => "Sync directory changes", "zh-Hans-CN" => "实时同步通讯录变更"},
        %{
          "default" =>
            "Receive user and department changes over DingTalk Stream. Requires directory sync.",
          "zh-Hans-CN" => "通过钉钉 Stream 接收用户和部门变更；需先开启通讯录同步。"
        },
        :boolean,
        default: true,
        advanced: true
      ),
      field(
        "sync.pageSize",
        %{"default" => "Records per page", "zh-Hans-CN" => "每页同步数量"},
        %{
          "default" => "Number of users requested per page. Usually keep the default.",
          "zh-Hans-CN" => "每次从钉钉读取的用户数量，通常保留默认值。"
        },
        :integer,
        default: 50,
        min: 1,
        max: 100,
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
