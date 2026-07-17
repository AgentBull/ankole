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
  def api_version, do: 1

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
        %{"default" => "App Key", "zh-Hans-CN" => "应用 AppKey"},
        %{
          "default" => "Enterprise-internal app AppKey (also the Stream clientId).",
          "zh-Hans-CN" => "企业内部应用 AppKey（同时作为 Stream clientId）。"
        },
        :string,
        required: true
      ),
      field(
        "clientSecret",
        %{"default" => "App Secret", "zh-Hans-CN" => "应用 AppSecret"},
        %{"default" => "Enterprise-internal app AppSecret.", "zh-Hans-CN" => "企业内部应用 AppSecret。"},
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
      ),
      field(
        "baseURL",
        %{"default" => "Base URL", "zh-Hans-CN" => "基础 URL"},
        %{
          "default" => "Optional override for local end-to-end testing (both API domains).",
          "zh-Hans-CN" => "可选，本地端到端测试时覆盖新旧双域基址。"
        },
        :string,
        []
      )
    ]
  end

  defp identity_fields do
    [
      field(
        "clientId",
        %{"default" => "App Key", "zh-Hans-CN" => "应用 AppKey"},
        %{"default" => "Enterprise-internal app AppKey.", "zh-Hans-CN" => "企业内部应用 AppKey。"},
        :string,
        required: true
      ),
      field(
        "clientSecret",
        %{"default" => "App Secret", "zh-Hans-CN" => "应用 AppSecret"},
        %{"default" => "Enterprise-internal app AppSecret.", "zh-Hans-CN" => "企业内部应用 AppSecret。"},
        :secret,
        required: true,
        encrypted: true
      ),
      field(
        "oidc.enabled",
        %{"default" => "Enable login", "zh-Hans-CN" => "启用登录"},
        %{
          "default" => "Allows operators to sign in through DingTalk.",
          "zh-Hans-CN" => "允许管理员通过钉钉登录。"
        },
        :boolean,
        default: true
      ),
      field(
        "oidc.scope",
        %{"default" => "Login scope", "zh-Hans-CN" => "登录 scope"},
        %{
          "default" => "Authorization scope; corpid returns the chosen org id.",
          "zh-Hans-CN" => "授权 scope；corpid 可拿到所选组织 id。"
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
          "default" =>
            "Imports DingTalk contacts into Principals, department groups, and memberships.",
          "zh-Hans-CN" => "将钉钉通讯录导入 Principals、部门组和成员关系。"
        },
        :boolean,
        default: true
      ),
      field(
        "sync.websocket",
        %{"default" => "Incremental contact sync", "zh-Hans-CN" => "增量通讯录同步"},
        %{
          "default" => "Consumes DingTalk contact-change events when directory sync is enabled.",
          "zh-Hans-CN" => "通讯录同步开启时，通过 Stream 消费钉钉通讯录变更事件。"
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
