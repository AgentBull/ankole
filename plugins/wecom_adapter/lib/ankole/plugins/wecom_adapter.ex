defmodule Ankole.Plugins.WeComAdapter do
  @moduledoc """
  First-party WeCom (企业微信) plugin declaration.

  WeCom splits bot capability across two product lines, so this plugin uses
  both: the AI bot (botId + secret, one WebSocket long connection per bot) is
  the SignalsGateway chat adapter, and the self-built app (corpid + agentid +
  secrets) is the Principals login/directory provider. The capability face is
  trimmed to what the platforms actually offer: groups deliver only @-mention
  messages (`addressed_only`), media arrives in DMs only, there is no recall
  API (no `delete_entry`), no edit/reaction/reconciliation, and directory
  changes converge through periodic full sync (no realtime contact events
  without a public XML callback URL).
  """

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.WeComAdapter.AIStream
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionReconciler
  alias Ankole.Plugins.WeComAdapter.ConnectionSupervisor
  alias Ankole.Plugins.WeComAdapter.IdentityProvider
  alias Ankole.Plugins.WeComAdapter.Inbound
  alias Ankole.Plugins.WeComAdapter.Outbox

  @impl true
  def plugin_id, do: "wecom-adapter"

  @impl true
  def display_name do
    %{"default" => "WeCom Adapter", "zh-Hans-CN" => "企业微信适配器"}
  end

  @impl true
  def description do
    %{
      "default" =>
        "Connects WeCom AI bots as a signals provider and self-built apps as a login provider.",
      "zh-Hans-CN" => "连接企业微信智能机器人作为信号提供方、自建应用作为登录提供方。"
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
        id: "wecom",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "signals_gateway.wecom.bindings.<agent_uid>",
        config_module: Config,
        fields: chat_fields(),
        supported_group_message_modes: ["addressed_only"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        reply_preview_module: AIStream,
        connection_supervisor: ConnectionSupervisor,
        inbound_capabilities: ["entry_receive", "action_event"],
        outbound_capabilities: ["post_entry", "card"]
      },
      %{
        contract_id: "principals.identity_provider",
        id: "wecom",
        plugin_id: plugin_id(),
        display_name: adapter_display_name(),
        config_key_pattern: "principals.identity_providers.wecom.<id>",
        fields: identity_fields(),
        module: IdentityProvider,
        capabilities: [
          "oidc_authorization",
          "oidc_code_exchange",
          "credential_check",
          "directory_full_sync"
        ]
      }
    ]
  end

  @impl true
  def children do
    [
      {Registry, keys: :unique, name: Ankole.Plugins.WeComAdapter.ConnectionRegistry},
      {DynamicSupervisor,
       name: Ankole.Plugins.WeComAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
      ConnectionReconciler
    ]
  end

  defp adapter_display_name do
    %{"default" => "WeCom", "zh-Hans-CN" => "企业微信"}
  end

  defp chat_fields do
    [
      field(
        "botId",
        %{"default" => "Bot ID", "zh-Hans-CN" => "机器人 Bot ID"},
        %{
          "default" =>
            "AI bot id from the WeCom admin console (create the bot in API mode). The bot must be created by a corp super administrator, otherwise callbacks carry encrypted user ids that can never join the directory.",
          "zh-Hans-CN" =>
            "管理后台创建 API 模式智能机器人后获得的 Bot ID。机器人必须由企业超级管理员创建，否则回调里的 userid 是加密形态，永远无法与通讯录/登录身份合一。"
        },
        :string,
        required: true
      ),
      field(
        "secret",
        %{"default" => "Bot Secret", "zh-Hans-CN" => "机器人 Secret"},
        %{
          "default" => "Long-connection secret shown next to the Bot ID.",
          "zh-Hans-CN" => "与 Bot ID 同页展示的长连接专用 Secret。"
        },
        :secret,
        required: true,
        encrypted: true
      ),
      field(
        "group_message_mode",
        %{"default" => "Group message mode", "zh-Hans-CN" => "群消息模式"},
        %{
          "default" => "WeCom only delivers @-mention and DM messages to AI bots.",
          "zh-Hans-CN" => "企业微信仅将群内 @ 机器人与单聊消息投递给智能机器人。"
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
          "default" => "Namespace used when mapping WeCom users into Ankole subjects.",
          "zh-Hans-CN" => "映射企业微信用户到 Ankole 主体时使用的命名空间。"
        },
        :string,
        default: "wecom-main"
      ),
      field(
        "userName",
        %{"default" => "Output display name", "zh-Hans-CN" => "输出显示名"},
        %{
          "default" => "Name shown for outbound provider messages.",
          "zh-Hans-CN" => "发送 provider 消息时显示的名称。"
        },
        :string,
        default: "企业微信 / WeCom"
      )
    ]
  end

  defp identity_fields do
    [
      field(
        "corpId",
        %{"default" => "Corp ID", "zh-Hans-CN" => "企业 ID（CorpID）"},
        %{
          "default" => "Enterprise CorpID from My Company > Company information.",
          "zh-Hans-CN" => "「我的企业 → 企业信息」中的企业 ID。"
        },
        :string,
        required: true
      ),
      field(
        "agentId",
        %{"default" => "Agent ID", "zh-Hans-CN" => "自建应用 AgentId"},
        %{
          "default" => "AgentId of the self-built app that carries the WWLogin sign-in.",
          "zh-Hans-CN" => "承载扫码登录的自建应用 AgentId。"
        },
        :string,
        required: true
      ),
      field(
        "appSecret",
        %{"default" => "App Secret", "zh-Hans-CN" => "自建应用 Secret"},
        %{
          "default" =>
            "Self-built app Secret. Server calls require the deployment's egress IP in the app's trusted-IP list (error 60020 otherwise), and the login redirect domain must be a trusted domain of the app.",
          "zh-Hans-CN" => "自建应用 Secret。服务端调用要求部署出口 IP 配置在应用「企业可信IP」中（否则报 60020），登录回跳域名须配置为应用可信域名。"
        },
        :secret,
        required: true,
        encrypted: true
      ),
      field(
        "contactsSecret",
        %{"default" => "Contacts-sync Secret", "zh-Hans-CN" => "通讯录同步 Secret"},
        %{
          "default" =>
            "Secret from Security & Administration > Management tools > Contacts sync (with its own trusted-IP list). Without it directory sync is unavailable and signed-in users keep bare userids: since 2022-06-20 the ordinary app secret no longer returns names.",
          "zh-Hans-CN" =>
            "「安全与管理 → 管理工具 → 通讯录同步」的专用 Secret（有独立的可信 IP 配置）。不配则目录同步不可用、登录主体没有姓名：2022-06-20 起普通应用 Secret 拿不到姓名等敏感字段。"
        },
        :secret,
        encrypted: true
      ),
      field(
        "oidc.enabled",
        %{"default" => "Enable login", "zh-Hans-CN" => "启用登录"},
        %{
          "default" => "Allows operators to sign in with the WeCom WWLogin QR page.",
          "zh-Hans-CN" => "允许管理员通过企业微信扫码登录。"
        },
        :boolean,
        default: true
      ),
      field(
        "sync.contacts",
        %{"default" => "Sync directory", "zh-Hans-CN" => "同步通讯录"},
        %{
          "default" =>
            "Imports the WeCom directory into Principals, department groups, and memberships. Requires the contacts-sync Secret; changes converge through periodic full sync.",
          "zh-Hans-CN" => "将企业微信通讯录导入 Principals、部门组和成员关系。需要通讯录同步 Secret；变更经周期全量同步收敛。"
        },
        :boolean,
        default: true
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
