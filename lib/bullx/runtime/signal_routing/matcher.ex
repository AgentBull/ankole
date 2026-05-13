defmodule BullX.Runtime.SignalRouting.Matcher do
  @moduledoc false

  alias BullX.Runtime.SignalRouting.{RoutingContext, Rule}

  @fixed_match_fields [
    {:adapter, :adapter},
    {:channel_id, :channel_id},
    {:scope_id, :scope_id},
    {:thread_id, :thread_id},
    {:actor_external_id, :actor_external_id},
    {:actor_bot, :actor_bot},
    {:event_type, :event_type},
    {:event_name, :event_name}
  ]

  @spec normalize_rules([Rule.t()]) :: {:ok, [Rule.t()]} | {:error, term()}
  def normalize_rules(rules) when is_list(rules) do
    case Enum.find(rules, &(destination_key(&1) == :error)) do
      nil -> {:ok, sort_rules(rules)}
      rule -> {:error, {:invalid_rule_destination, Map.get(rule, :id)}}
    end
  end

  @spec match(RoutingContext.t(), [Rule.t()]) :: [Rule.t()]
  def match(%RoutingContext{} = context, rules) when is_list(rules) do
    rules
    |> Enum.filter(&matches?(context, &1))
    |> winning_rules()
  end

  @spec matches?(RoutingContext.t(), Rule.t()) :: boolean()
  def matches?(%RoutingContext{} = context, %Rule{} = rule) do
    rule.signal_type == context.signal_type and fixed_columns_match?(context, rule) and
      routing_fact_matches?(context, rule)
  end

  @spec sort_rules([Rule.t()]) :: [Rule.t()]
  def sort_rules(rules) do
    Enum.sort_by(rules, fn rule -> {-(rule.priority || 0), rule.key || ""} end)
  end

  defp winning_rules([]), do: []

  defp winning_rules([_ | _] = matching_rules) do
    sorted = sort_rules(matching_rules)

    case sorted do
      [%Rule{route_action: :drop_signal} = rule | _rest] ->
        [rule]

      [_top | _rest] ->
        sorted
        |> Enum.reject(&(&1.route_action == :drop_signal))
        |> Enum.group_by(&Rule.destination_key/1)
        |> Map.values()
        |> Enum.map(fn [winner | _rules] -> winner end)
        |> sort_rules()
    end
  end

  defp fixed_columns_match?(context, rule) do
    Enum.all?(@fixed_match_fields, fn {rule_field, context_field} ->
      field_matches?(Map.get(rule, rule_field), Map.get(context, context_field))
    end)
  end

  defp field_matches?(nil, _context_value), do: true
  defp field_matches?(value, value), do: true
  defp field_matches?(_rule_value, _context_value), do: false

  defp routing_fact_matches?(_context, %Rule{routing_fact_key: nil, routing_fact_value: nil}),
    do: true

  defp routing_fact_matches?(
         %RoutingContext{routing_facts: facts},
         %Rule{routing_fact_key: key, routing_fact_value: expected}
       )
       when is_binary(key) and is_binary(expected) do
    case Map.fetch(facts, key) do
      {:ok, ^expected} -> true
      {:ok, values} when is_list(values) -> expected in values
      _other -> false
    end
  end

  defp routing_fact_matches?(_context, _rule), do: false

  defp destination_key(%Rule{route_action: :deliver_agent, agent_principal_id: id})
       when is_binary(id),
       do: Rule.destination_key(%Rule{route_action: :deliver_agent, agent_principal_id: id})

  defp destination_key(%Rule{route_action: :drop_signal, sink_kind: :blackhole}),
    do: Rule.destination_key(%Rule{route_action: :drop_signal, sink_kind: :blackhole})

  defp destination_key(_rule), do: :error
end
