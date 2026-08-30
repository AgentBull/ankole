defmodule Ankole.Plugins.MapHelpersTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.MapHelpers

  test "fetch_value reads provider JSON string keys only" do
    assert MapHelpers.fetch_value(%{"name" => "string"}, "name") == "string"
    assert MapHelpers.fetch_value(%{name: "atom"}, "name") == nil
    assert MapHelpers.fetch_value(%{"name" => "string", name: "atom"}, "name") == "string"
    assert MapHelpers.fetch_value(%{name: "atom"}, :name) == nil
  end

  test "fetch_value preserves false and returns nil for misses and non-maps" do
    assert MapHelpers.fetch_value(%{"flag" => false}, "flag") == false
    assert MapHelpers.fetch_value(%{}, "name") == nil
    assert MapHelpers.fetch_value(%{}, "map_helpers_never_defined_key_20260717") == nil
    assert MapHelpers.fetch_value(nil, "name") == nil
    assert MapHelpers.fetch_value([], "name") == nil
  end

  test "fetch_map returns only map values, otherwise the default" do
    assert MapHelpers.fetch_map(%{"event" => %{"id" => 1}}, "event", %{}) == %{"id" => 1}
    assert MapHelpers.fetch_map(%{"event" => "scalar"}, "event", %{}) == %{}
    assert MapHelpers.fetch_map(nil, "event", %{"d" => true}) == %{"d" => true}
  end

  test "fetch_list returns only list values, otherwise an empty list" do
    assert MapHelpers.fetch_list(%{"items" => [1, 2]}, "items") == [1, 2]
    assert MapHelpers.fetch_list(%{"items" => "scalar"}, "items") == []
    assert MapHelpers.fetch_list(nil, "items") == []
  end

  test "optional_text trims binaries to nil-or-content and rejects non-binaries" do
    assert MapHelpers.optional_text(%{"text" => "  hello  "}, "text") == "hello"
    assert MapHelpers.optional_text(%{"text" => "   "}, "text") == nil
    assert MapHelpers.optional_text(%{"text" => 42}, "text") == nil
    assert MapHelpers.optional_text(nil, "text") == nil
  end

  test "presence trims binaries and maps everything else to nil" do
    assert MapHelpers.presence(" value ") == "value"
    assert MapHelpers.presence("") == nil
    assert MapHelpers.presence(:atom) == nil
  end

  test "compact_map drops only nil values" do
    assert MapHelpers.compact_map(%{"a" => nil, "b" => false, "c" => "", "d" => []}) ==
             %{"b" => false, "c" => "", "d" => []}
  end

  test "compact_metadata_map drops nil and empty-list values" do
    assert MapHelpers.compact_metadata_map(%{"a" => nil, "b" => [], "c" => "", "d" => %{}}) ==
             %{"c" => "", "d" => %{}}
  end

  test "put_present skips nil and empty-string values" do
    assert MapHelpers.put_present(%{}, "a", nil) == %{}
    assert MapHelpers.put_present(%{}, "a", "") == %{}
    assert MapHelpers.put_present(%{}, "a", false) == %{"a" => false}
    assert MapHelpers.put_present(%{}, "a", 0) == %{"a" => 0}
  end

  test "maybe_put_nonempty_map skips nil and empty maps" do
    assert MapHelpers.maybe_put_nonempty_map(%{}, "a", nil) == %{}
    assert MapHelpers.maybe_put_nonempty_map(%{}, "a", %{}) == %{}
    assert MapHelpers.maybe_put_nonempty_map(%{}, "a", %{"k" => 1}) == %{"a" => %{"k" => 1}}
    assert MapHelpers.maybe_put_nonempty_map(%{}, "a", "text") == %{"a" => "text"}
  end

  test "collect_results keeps order and halts on the first error" do
    assert MapHelpers.collect_results([{:ok, 1}, {:ok, 2}]) == {:ok, [1, 2]}
    assert MapHelpers.collect_results([{:ok, 1}, {:error, :boom}, {:ok, 2}]) == {:error, :boom}
    assert MapHelpers.collect_results([]) == {:ok, []}
  end

  test "required_string trims and rejects missing, blank, and non-string values" do
    assert MapHelpers.required_string(%{"a" => " x "}, "a") == {:ok, "x"}
    assert MapHelpers.required_string(%{"a" => "  "}, "a") == {:error, {:missing, "a"}}
    assert MapHelpers.required_string(%{}, "a") == {:error, {:missing, "a"}}
    assert MapHelpers.required_string(%{"a" => 1}, "a") == {:error, {:missing, "a"}}
  end

  test "optional_string trims, falls back to the default, and rejects non-strings" do
    assert MapHelpers.optional_string(%{"a" => " x "}, "a", "d") == {:ok, "x"}
    assert MapHelpers.optional_string(%{"a" => "  "}, "a", "d") == {:ok, "d"}
    assert MapHelpers.optional_string(%{}, "a", "d") == {:ok, "d"}
    assert MapHelpers.optional_string(%{"a" => 1}, "a", "d") == {:error, {:invalid_string, "a"}}
  end

  test "optional_boolean keeps booleans, falls back, and rejects other values" do
    assert MapHelpers.optional_boolean(%{"a" => false}, "a", true) == {:ok, false}
    assert MapHelpers.optional_boolean(%{}, "a", true) == {:ok, true}

    assert MapHelpers.optional_boolean(%{"a" => "yes"}, "a", true) ==
             {:error, {:invalid_boolean, "a"}}
  end

  test "integer_between enforces the inclusive range and falls back on nil" do
    assert MapHelpers.integer_between(%{"a" => 3}, "a", 1, 1, 5) == {:ok, 3}
    assert MapHelpers.integer_between(%{}, "a", 1, 1, 5) == {:ok, 1}

    assert MapHelpers.integer_between(%{"a" => 6}, "a", 1, 1, 5) ==
             {:error, {:invalid_integer_range, "a", 1, 5}}

    assert MapHelpers.integer_between(%{"a" => "3"}, "a", 1, 1, 5) ==
             {:error, {:invalid_integer_range, "a", 1, 5}}
  end
end
