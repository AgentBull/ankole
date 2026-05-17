defmodule BullX.EventBus.DedupeTest do
  use ExUnit.Case, async: true

  alias BullX.EventBus.Dedupe

  test "hashes the documented length-prefixed UTF-8 encoding" do
    source = "feishu://connected-realm/default"
    id = "event-1"

    documented_input =
      "cloudevents:" <>
        Integer.to_string(byte_size(source)) <>
        ":" <>
        source <>
        ":" <>
        Integer.to_string(byte_size(id)) <>
        ":" <>
        id

    assert documented_input == "cloudevents:32:feishu://connected-realm/default:7:event-1"

    expected_hash = BullX.Ext.generic_hash(documented_input)
    assert is_binary(expected_hash)
    assert byte_size(expected_hash) == 64
    assert String.match?(expected_hash, ~r/\A[0-9a-f]{64}\z/)

    assert {:ok, ^expected_hash} = Dedupe.hash(source, id)
  end

  test "byte length prefixes prevent boundary-shifting collisions" do
    # Without length prefixes, ("a:b", "c") and ("a", "b:c") would produce the
    # same concatenated input. The byte_size prefix is what makes the encoding
    # injective; this regression test pins that property.
    {:ok, hash_a} = Dedupe.hash("a:b", "c")
    {:ok, hash_b} = Dedupe.hash("a", "b:c")
    refute hash_a == hash_b
  end

  test "byte_size measures UTF-8 bytes, not code points" do
    # "中" is 3 UTF-8 bytes, 1 code point. The prefix must use byte_size so
    # multibyte sources do not collide with single-byte sources of the same
    # apparent length.
    source = "中"
    assert byte_size(source) == 3

    expected_prefix = "cloudevents:3:中:1:x"
    expected_hash = BullX.Ext.generic_hash(expected_prefix)

    assert {:ok, ^expected_hash} = Dedupe.hash(source, "x")
  end
end
