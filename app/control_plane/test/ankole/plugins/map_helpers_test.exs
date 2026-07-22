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

  test "maybe_put skips nil and empty-string values" do
    assert MapHelpers.maybe_put(%{}, "a", nil) == %{}
    assert MapHelpers.maybe_put(%{}, "a", "") == %{}
    assert MapHelpers.maybe_put(%{}, "a", false) == %{"a" => false}
    assert MapHelpers.maybe_put(%{}, "a", 0) == %{"a" => 0}
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
end
