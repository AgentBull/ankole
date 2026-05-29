defmodule BullX.MailBox.Matcher do
  @moduledoc """
  MailBox delivery-rule matcher wrapper.

  The Rust NIF owns CEL evaluation. `BullX.MailBox.route/2` evaluates delivery
  rules independently so one mail can fan out to every matching receiver.
  """

  alias BullX.MailBox.DeliveryRule

  @type diagnostic :: {String.t(), atom(), String.t()}
  @type match_result ::
          {:ok, {:matched, String.t(), [diagnostic()]}}
          | {:ok, {:no_match, [diagnostic()]}}
          | {:error, String.t()}

  @spec match([DeliveryRule.t() | map()], map()) :: match_result()
  def match(rules, routing_context) when is_list(rules) and is_map(routing_context) do
    case BullX.Ext.mailbox_match_delivery_rule(encode_rules(rules), routing_context) do
      {:matched, rule_id, diagnostics} -> {:ok, {:matched, rule_id, diagnostics}}
      {:no_match, diagnostics} -> {:ok, {:no_match, diagnostics}}
      {:error, reason} -> {:error, to_string(reason)}
    end
  rescue
    ErlangError -> {:error, "mailbox route matcher nif unavailable"}
    UndefinedFunctionError -> {:error, "mailbox route matcher nif unavailable"}
  catch
    :error, :nif_not_loaded -> {:error, "mailbox route matcher nif unavailable"}
    kind, reason -> {:error, "mailbox route matcher #{kind}: #{inspect(reason)}"}
  end

  defp encode_rules(rules), do: Enum.map(rules, &encode_rule/1)

  defp encode_rule(%DeliveryRule{} = rule) do
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
