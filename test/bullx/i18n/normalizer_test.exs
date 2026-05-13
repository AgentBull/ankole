defmodule BullX.I18n.NormalizerTest do
  use ExUnit.Case, async: true

  alias BullX.I18n.Normalizer

  test "flattens a nested table into dotted keys" do
    input = %{
      "__meta__" => %{"bcp47" => "en-US"},
      "examples" => %{
        "greeting" => "Hello, {$name}!",
        "profile" => %{"title" => "Profile"}
      }
    }

    %{messages: messages, meta: meta} = Normalizer.normalize(input)

    # MF2 canonical form wraps simple patterns in {{...}} markers so
    # the catalog stores a parser-canonical string. Runtime format/3
    # strips those markers before returning the final output.
    assert Map.has_key?(messages, "examples.greeting")
    assert messages["examples.greeting"] =~ "{$name}"

    assert {:ok, "Hello, Alice!"} =
             Localize.Message.format(messages["examples.greeting"], %{name: "Alice"})

    assert Map.has_key?(messages, "examples.profile.title")
    assert {:ok, "Profile"} = Localize.Message.format(messages["examples.profile.title"], %{})
    assert meta.bcp47 == "en-US"
  end

  test "accepts a rich-leaf table with __mf2__ = true" do
    input = %{
      "checkout_button" => %{
        "__mf2__" => true,
        "message" => "Checkout {$total}",
        "description" => "Primary CTA"
      }
    }

    %{messages: messages} = Normalizer.normalize(input)
    assert Map.keys(messages) == ["checkout_button"]
  end

  test "canonicalises MF2 source so structurally equivalent .match messages dedupe" do
    # Same MF2 semantics, different surface indentation on variant lines.
    src_a = """
    .input {$count :integer}
    .match $count
      1 {{one}}
      * {{many}}
    """

    src_b = """
    .input {$count :integer}
    .match $count
    1 {{one}}
    * {{many}}
    """

    input = %{"a" => src_a, "b" => src_b}
    %{messages: messages} = Normalizer.normalize(input)
    assert messages["a"] == messages["b"]
  end

  test "raises on MF2 syntax error" do
    input = %{"bad" => "{unbalanced"}
    assert_raise Normalizer.Error, fn -> Normalizer.normalize(input, file: "test.toml") end
  end

  test "raises on unsupported leaf type" do
    input = %{"numeric" => 42}
    assert_raise Normalizer.Error, fn -> Normalizer.normalize(input, file: "test.toml") end
  end

  test "meta fallback is kept as a binary BCP 47 tag" do
    input = %{"__meta__" => %{"fallback" => "en-US"}}
    %{meta: meta} = Normalizer.normalize(input)
    assert meta.fallback == "en-US"
  end

  test "raises on an unknown meta key" do
    input = %{"__meta__" => %{"fall_back" => "en-US"}}

    assert_raise Normalizer.Error, ~r/unknown meta key "fall_back"/, fn ->
      Normalizer.normalize(input, file: "test.toml")
    end
  end

  test "raises when a known meta key carries a non-string value" do
    input = %{"__meta__" => %{"revision" => 42}}

    assert_raise Normalizer.Error, ~r/meta key "revision" must be a string/, fn ->
      Normalizer.normalize(input, file: "test.toml")
    end
  end
end
