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
end
