defmodule Ankole.Kernel.JSONTest do
  use ExUnit.Case, async: true
  alias Ankole.Kernel.JSON, as: Codec

  test "ordinary JSON retains Torque's representation and errors" do
    for value <- [nil, true, 1, 1.25, "中文🙂", [1, %{"a" => false}], %{key: "value"}] do
      assert Codec.encode(value) == Torque.encode(value)
      json = Torque.encode!(value)
      assert Codec.decode(json) == Torque.decode(json)
    end

    assert Codec.decode("invalid") == Torque.decode("invalid")
  end

  test "Torque options reach the Torque path" do
    long = String.duplicate("x", 100)
    json = Torque.encode!(%{"keep" => long, "drop" => long})

    assert {:ok, %{"keep" => kept}} = Codec.decode(json, strings: :copy)
    assert :binary.referenced_byte_size(kept) == byte_size(long)
    assert Codec.encode!(%{"a" => 1}, dirty: true) == Torque.encode!(%{"a" => 1})

    deep = Enum.reduce(1..300, %{"keep" => long}, fn _, child -> %{"content" => child} end)
    deep_json = Codec.encode!(deep, dirty: true)
    assert deep_json == Codec.encode!(deep)

    {:ok, decoded} = Codec.decode(deep_json, strings: :copy)
    assert decoded == deep
    kept = Enum.reduce(1..300, decoded, fn _, %{"content" => child} -> child end)["keep"]
    assert :binary.referenced_byte_size(kept) == byte_size(long)
  end

  test "nested transport accepts 512 containers and rejects 513 in both directions" do
    for depth <- [128, 129, 260, 512] do
      value = Enum.reduce(1..depth, "leaf", fn _, child -> %{"content" => child} end)
      assert {:ok, json} = Codec.encode(value)
      assert {:ok, ^value} = Codec.decode(json)
      assert Codec.encode!(value) == json
      assert Codec.decode!(json) == value
    end

    value = Enum.reduce(1..513, nil, fn _, child -> [child] end)
    assert {:error, :nesting_too_deep} = Codec.encode(value)

    assert {:error, :nesting_too_deep} =
             Codec.decode(String.duplicate("[", 513) <> "null" <> String.duplicate("]", 513))
  end

  test "deep decoding rejects trailing input and retains string and duplicate-key semantics" do
    prefix = String.duplicate("[", 130)
    suffix = String.duplicate("]", 130)
    inner = ~s({"key":"old","key":"[\\\"{}]"})
    json = prefix <> inner <> suffix
    expected = Enum.reduce(1..130, %{"key" => "[\"{}]"}, fn _, child -> [child] end)
    assert {:ok, ^expected} = Codec.decode(json <> " \t\r\n")
    assert {:error, _} = Codec.decode(json <> " true")

    for invalid <- ["invalid", "1e999", ~s("\\uD800")] do
      assert {:error, _} = Codec.decode(prefix <> invalid <> suffix)
    end
  end

  test "deep encoding preserves non-bang errors for invalid leaves and keys" do
    for invalid <- [self(), <<255>>, %{1.25 => nil}, %{[] => nil}] do
      assert {:error, reason} = Torque.encode(invalid)
      value = Enum.reduce(1..130, invalid, fn _, child -> [child] end)
      assert {:error, ^reason} = Codec.encode(value)
    end
  end

  test "Torque object tuples count toward the enclosing transport depth" do
    tuple = {[{"value", nil}]}
    valid = Enum.reduce(1..511, tuple, fn _, child -> [child] end)
    expected = Enum.reduce(1..511, %{"value" => nil}, fn _, child -> [child] end)
    assert {:ok, json} = Codec.encode(valid)
    assert {:ok, ^expected} = Codec.decode(json)
    assert {:error, :nesting_too_deep} = Codec.encode([valid])
  end
end
