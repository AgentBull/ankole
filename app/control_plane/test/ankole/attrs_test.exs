defmodule Ankole.AttrsTest do
  use ExUnit.Case, async: true

  alias Ankole.Attrs

  test "optional text trims strings and treats blanks and non-strings as absent" do
    assert Attrs.optional_text("  保存格式\n") == "保存格式"
    assert Attrs.optional_text("\t\r\n ") == nil
    assert Attrs.optional_text("") == nil

    for value <- [nil, false, 0, :name, [], %{}] do
      assert Attrs.optional_text(value) == nil
    end
  end

  test "integer values require the complete string and preserve zero and signs" do
    assert Attrs.integer_value(0) == 0
    assert Attrs.integer_value(-3) == -3
    assert Attrs.integer_value("0") == 0
    assert Attrs.integer_value("+42") == 42
    assert Attrs.integer_value("-42") == -42

    for value <- [nil, false, 1.0, "", " 42", "42 ", "42px", "4.2"] do
      assert Attrs.integer_value(value) == nil
    end
  end

  test "atom keys retain precedence when their values are nil or false" do
    assert Attrs.get(%{:primary => false, "primary" => true}, :primary) == false
    assert Attrs.get(%{:primary => nil, "primary" => true}, :primary, :default) == nil
    assert Attrs.get(%{"primary" => false}, :primary, :default) == false
    assert Attrs.get(%{}, :primary, :default) == :default
  end

  test "external key normalization keeps non-atom keys and nested values unchanged" do
    attrs = %{:name => "tool", "nested" => %{enabled: false}, 1 => [%{value: 1}]}

    assert Attrs.normalize_external_attrs(attrs) == %{
             "name" => "tool",
             "nested" => %{enabled: false},
             1 => [%{value: 1}]
           }
  end

  test "datetime parsing keeps instants and rejects epoch numbers and malformed text" do
    datetime = ~U[2026-10-20 04:05:06.123456Z]
    assert Attrs.parse_datetime(datetime) == datetime
    assert Attrs.parse_datetime("2026-10-20T12:05:06.123456+08:00") == datetime

    for value <- [nil, false, 1_792_468_800, "1792468800", "invalid", ""] do
      assert Attrs.parse_datetime(value) == nil
    end
  end

  test "required text preserves the caller's missing-value reason" do
    assert Attrs.required_text("  name\n", {:missing, :name}) == {:ok, "name"}

    assert Attrs.required_text(" ", {:missing_text, "name"}) ==
             {:error, {:missing_text, "name"}}

    for value <- [nil, false, 0, [], %{}] do
      assert Attrs.required_text(value, :invalid_request) == {:error, :invalid_request}
    end
  end

  test "truthy key reads preserve preferred key order and fallback false" do
    values = %{:enabled => "atom", "enabled" => "string"}
    assert Attrs.get_truthy(values, :enabled) == "atom"
    assert Attrs.get_truthy(values, "enabled") == "string"

    assert Attrs.get_truthy(%{:enabled => false, "enabled" => true}, :enabled) == true
    assert Attrs.get_truthy(%{:enabled => true, "enabled" => false}, "enabled") == true
    assert Attrs.get_truthy(%{:enabled => nil, "enabled" => false}, :enabled) == false
    assert Attrs.get_truthy(%{:enabled => false, "enabled" => nil}, "enabled") == false
    assert Attrs.get_truthy(%{:enabled => false, "enabled" => false}, :enabled) == false
    assert Attrs.get_truthy(%{}, :enabled) == nil
  end

  test "string-first fallback reads never create an atom for an unknown key" do
    key = "external-key-" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert Attrs.get_truthy(%{}, key) == nil
    assert Attrs.get_truthy(%{key => "value"}, key) == "value"
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end

  test "string-first presence reads keep nil and false instead of falling back" do
    assert Attrs.get_string_first(%{:enabled => "atom", "enabled" => "string"}, "enabled") ==
             "string"

    assert Attrs.get_string_first(%{:enabled => true, "enabled" => false}, "enabled") == false
    assert Attrs.get_string_first(%{:enabled => true, "enabled" => nil}, "enabled") == nil
    assert Attrs.get_string_first(%{enabled: "atom"}, "enabled") == "atom"
    assert Attrs.get_string_first(%{enabled: false}, "enabled") == false
    assert Attrs.get_string_first(%{enabled: nil}, "enabled") == nil
    assert Attrs.get_string_first(%{}, "enabled") == nil
  end

  test "string-first presence reads never create an atom for an unknown key" do
    key = "presence-key-" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
    assert Attrs.get_string_first(%{}, key) == nil
    assert Attrs.get_string_first(%{key => false}, key) == false
    assert Attrs.get_string_first(%{key => nil}, key) == nil
    assert_raise ArgumentError, fn -> String.to_existing_atom(key) end
  end
end
