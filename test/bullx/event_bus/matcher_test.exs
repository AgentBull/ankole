defmodule BullX.EventBus.MatcherTest do
  use ExUnit.Case, async: true

  alias BullX.EventBus.Matcher

  test "Rust matcher returns the first matching rule by priority" do
    rules = [
      %{"id" => "fallback", "priority" => 20, "match_expr" => "true"},
      %{"id" => "message", "priority" => 10, "match_expr" => "type == \"bullx.message.created\""}
    ]

    context = %{"type" => "bullx.message.created"}

    assert {:ok, {:matched, "message", []}} = Matcher.match(rules, context)
  end

  test "Rust matcher accepts negative priorities for code-owned builtin rules" do
    rules = [
      %{"id" => "pg", "priority" => 1, "match_expr" => "true"},
      %{"id" => "builtin", "priority" => -1, "match_expr" => "true"}
    ]

    assert :ok = Matcher.validate_route_table(rules)
    assert {:ok, {:matched, "builtin", []}} = Matcher.match(rules, %{})
  end

  test "one rule evaluation error is a non-match with diagnostics" do
    rules = [
      %{"id" => "bad", "priority" => 10, "match_expr" => "missing.value"},
      %{"id" => "fallback", "priority" => 20, "match_expr" => "true"}
    ]

    assert {:ok, {:matched, "fallback", [{"bad", :condition_execution, _reason}]}} =
             Matcher.match(rules, %{"type" => "x"})
  end

  test "duplicate priority is invalid at the matcher boundary" do
    rules = [
      %{"id" => "a", "priority" => 10, "match_expr" => "true"},
      %{"id" => "b", "priority" => 10, "match_expr" => "true"}
    ]

    assert {:error, _reason} = Matcher.validate_route_table(rules)
  end
end
