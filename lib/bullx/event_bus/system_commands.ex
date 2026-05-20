defmodule BullX.EventBus.SystemCommands do
  @moduledoc """
  Code-owned Event Routing Rules for built-in system commands.

  These rules are merged into the runtime `RoutingTable` snapshot and are not
  persisted in `event_routing_rules`. Database-owned rules keep positive
  priorities; built-in system command rules use reserved negative priorities so
  they run before configured routes without occupying PostgreSQL priority rows.
  """

  alias BullX.EventBus.EventRoutingRule

  @rules [
    %{
      id: "019f0000-0000-7000-8000-000000000001",
      name: "system command: command",
      command_name: "command",
      priority: -20,
      target_ref: "bullx.system.command_list"
    },
    %{
      id: "019f0000-0000-7000-8000-000000000002",
      name: "system command: status",
      command_name: "status",
      priority: -19,
      target_ref: "bullx.system.status"
    }
  ]

  @spec builtin_routing_rules() :: [EventRoutingRule.t()]
  def builtin_routing_rules do
    Enum.map(@rules, &rule_struct/1)
  end

  defp rule_struct(rule) do
    %EventRoutingRule{
      id: rule.id,
      name: rule.name,
      active: true,
      priority: rule.priority,
      match_expr:
        ~s(type == "bullx.command.invoked" && routing_facts.command_name == "#{rule.command_name}"),
      target_type: :command,
      target_ref: rule.target_ref,
      scope_fields: ["channel.adapter", "channel.id", "scope.id", "routing_facts.command_name"]
    }
  end
end
