defmodule Ankole.Plugins.LarkAdapter do
  @moduledoc """
  First-party Lark / Feishu plugin declaration.
  """

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Plugins.LarkAdapter.Outbox

  @impl true
  def plugin_id, do: "lark-adapter"

  @impl true
  def api_version, do: 1

  @impl true
  def display_name, do: "Lark / Feishu"

  @impl true
  def description do
    "Connects Lark / Feishu self-built apps to SignalsGateway and Principals."
  end

  @impl true
  def app_config_patterns, do: Config.app_config_patterns()

  @impl true
  def setup_metadata do
    # Setup metadata is data, not UI code. The control plane can render these
    # fields without loading provider-specific forms into the core application.
    [
      %{
        contract_id: "signals_gateway.adapter.setup",
        adapter_id: "lark",
        default_binding_name: "lark",
        display_name: "Lark / Feishu",
        config_key_pattern: "signals_gateway.lark.bindings.<id>",
        fields: chat_fields(),
        group_message_modes: [
          %{
            value: "addressed_only",
            binding_policy: "ignore",
            label: "Addressed messages only"
          },
          %{
            value: "observe_all",
            binding_policy: "record_only",
            label: "Observe unaddressed group messages"
          },
          %{
            value: "may_intervene",
            binding_policy: "may_intervene",
            label: "Let the agent consider intervening"
          }
        ]
      },
      %{
        contract_id: "principals.identity_provider.setup",
        adapter_id: "lark",
        display_name: "Lark / Feishu",
        config_key_pattern: "principals.identity_providers.lark.<id>",
        fields: identity_fields()
      }
    ]
  end

  @impl true
  def adapter_declarations do
    # The plugin exposes separate chat and identity contracts because message
    # transport and Principal identity have different lifecycles and consumers.
    [
      %{
        contract_id: "signals_gateway.adapter",
        id: "lark",
        plugin_id: plugin_id(),
        display_name: "Lark / Feishu",
        ingress_module: Inbound,
        outbox_module: Outbox,
        connection_supervisor: ConnectionSupervisor,
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
        display_name: "Lark / Feishu",
        module: IdentityProvider,
        capabilities: [
          "oidc_authorization",
          "oidc_code_exchange",
          "user_full_sync",
          "department_full_sync",
          "contact_realtime_sync"
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
      ConnectionReconciler
    ]
  end

  defp chat_fields do
    [
      field("appId", "App ID", :string, required: true),
      field("appSecret", "App Secret", :secret, required: true, encrypted: true),
      field("domain", "Domain", :select, default: "feishu", options: ["feishu", "lark"]),
      field("group_message_mode", "Group message mode", :select,
        default: "observe_all",
        options: ["addressed_only", "observe_all", "may_intervene"]
      ),
      field("platformSubjectNamespace", "Platform subject namespace", :string,
        default: "lark-main"
      ),
      field("userName", "Output display name", :string, default: "Lark / Feishu"),
      field("streamingEnabled", "Streaming cards", :boolean, default: true),
      field("streamUpdateIntervalMs", "Streaming update interval", :integer, default: 800),
      field("streamBufferThreshold", "Streaming buffer threshold", :integer, default: 24)
    ]
  end

  defp identity_fields do
    [
      field("appId", "App ID", :string, required: true),
      field("appSecret", "App Secret", :secret, required: true, encrypted: true),
      field("domain", "Domain", :select, default: "feishu", options: ["feishu", "lark"]),
      field("oidc.enabled", "Enable OIDC", :boolean, default: true),
      field("oidc.scopes", "OIDC scopes", :string_array,
        default: ["contact:user.employee_id:readonly"]
      ),
      field("sync.users", "Sync users", :boolean, default: true),
      field("sync.departments", "Sync departments", :boolean, default: true),
      field("sync.websocket", "Realtime contact sync", :boolean, default: true),
      field("sync.pageSize", "Sync page size", :integer, default: 50, min: 1, max: 50)
    ]
  end

  defp field(path, label, type, opts) do
    opts
    |> Map.new()
    |> Map.merge(%{path: path, label: label, type: Atom.to_string(type)})
  end
end
