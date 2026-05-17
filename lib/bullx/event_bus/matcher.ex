defmodule BullX.EventBus.Matcher do
  @moduledoc """
  EventBus route matcher wrapper.

  The Rust NIF owns CEL evaluation and first-match route selection. This module
  keeps Elixir callers on a small, typed boundary.
  """

  alias BullX.EventBus.EventRoutingRule

  @type diagnostic :: {String.t(), atom(), String.t()}
  @type match_result ::
          {:ok, {:matched, String.t(), [diagnostic()]}}
          | {:ok, {:no_match, [diagnostic()]}}
          | {:error, String.t()}

  @spec validate_route_table([EventRoutingRule.t() | map()]) :: :ok | {:error, String.t()}
  def validate_route_table(rules) when is_list(rules) do
    case BullX.Ext.eventbus_route_table_validate(encode_rules(rules)) do
      true -> :ok
      {:error, reason} -> {:error, to_string(reason)}
    end
  rescue
    ErlangError -> {:error, "eventbus route matcher nif unavailable"}
    UndefinedFunctionError -> {:error, "eventbus route matcher nif unavailable"}
  catch
    :error, :nif_not_loaded -> {:error, "eventbus route matcher nif unavailable"}
    kind, reason -> {:error, "eventbus route matcher #{kind}: #{inspect(reason)}"}
  end

  @spec match([EventRoutingRule.t() | map()], map()) :: match_result()
  def match(rules, routing_context) when is_list(rules) and is_map(routing_context) do
    case BullX.Ext.eventbus_match_route(encode_rules(rules), routing_context) do
      {:matched, rule_id, diagnostics} -> {:ok, {:matched, rule_id, diagnostics}}
      {:no_match, diagnostics} -> {:ok, {:no_match, diagnostics}}
      {:error, reason} -> {:error, to_string(reason)}
    end
  rescue
    ErlangError -> {:error, "eventbus route matcher nif unavailable"}
    UndefinedFunctionError -> {:error, "eventbus route matcher nif unavailable"}
  catch
    :error, :nif_not_loaded -> {:error, "eventbus route matcher nif unavailable"}
    kind, reason -> {:error, "eventbus route matcher #{kind}: #{inspect(reason)}"}
  end

  defp encode_rules(rules), do: Enum.map(rules, &encode_rule/1)

  defp encode_rule(%EventRoutingRule{} = rule) do
    %{
      "id" => rule.id,
      "priority" => rule.priority,
      "match_expr" => rule.match_expr
    }
  end

  defp encode_rule(%{} = rule) do
    %{
      "id" => Map.get(rule, :id, Map.get(rule, "id")),
      "priority" => Map.get(rule, :priority, Map.get(rule, "priority")),
      "match_expr" => Map.get(rule, :match_expr, Map.get(rule, "match_expr"))
    }
  end
end
