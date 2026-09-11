defmodule Ankole.Plugins.EmailAdapter do
  @moduledoc "First-party email (IMAP and SMTP) consumer IM adapter."

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.EmailAdapter.Config
  alias Ankole.Plugins.EmailAdapter.ConnectionReconciler
  alias Ankole.Plugins.EmailAdapter.ConnectionSupervisor
  alias Ankole.Plugins.EmailAdapter.Inbound
  alias Ankole.Plugins.EmailAdapter.Outbox

  @impl true
  def plugin_id, do: "email-adapter"

  @impl true
  def display_name, do: %{"default" => "Email Adapter", "zh-Hans-CN" => "邮件适配器"}

  @impl true
  def description do
    %{
      "default" => "Connects a dedicated mailbox over IMAP and SMTP as a signals provider.",
      "zh-Hans-CN" => "通过 IMAP 收信、SMTP 发信，把一个专用邮箱接入为信号提供方。"
    }
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "email",
        adapter_category: "email",
        plugin_id: plugin_id(),
        display_name: %{"default" => "Email", "zh-Hans-CN" => "邮件"},
        config_key_pattern: "signals_gateway.email.bindings.<id>",
        config_module: Config,
        fields: Config.fields(),
        supported_group_message_modes: ["addressed_only", "observe_all", "may_intervene"],
        ingress_module: Inbound,
        outbox_module: Outbox,
        connection_supervisor: ConnectionSupervisor,
        inbound_capabilities: ["entry_receive"],
        outbound_capabilities: ["post_entry", "reply_entry"]
      }
    ]
  end

  @impl true
  def children do
    [
      {Registry, keys: :unique, name: Ankole.Plugins.EmailAdapter.ConnectionRegistry},
      {Task.Supervisor, name: Ankole.Plugins.EmailAdapter.SessionTaskSupervisor},
      {DynamicSupervisor,
       name: Ankole.Plugins.EmailAdapter.ConnectionDynamicSupervisor, strategy: :one_for_one},
      ConnectionReconciler
    ]
  end
end
