defmodule Ankole.E2E.PodContentStoryTest do
  use ExUnit.Case, async: true
  import Ankole.E2E.PodContentStory, only: [assert_named_facts!: 2]

  @research_facts [
    {"ordinary|normal|regular|body|small|普通|常规|正文|小号", "4\\.5\\s*(?:[:∶：]|to|比)\\s*1"},
    {"large|大号|大字体", "(?<![\\d.])3(?:\\.0)?\\s*(?:[:∶：]|to|比)\\s*1"}
  ]

  test "the actual research categories support English and Chinese associations" do
    for text <- [
          "Ordinary text needs 4.5:1; large text needs 3:1.",
          "Use 4.5 to 1 for normal text and 3.0:1 for large text.",
          "Ordinary text has a minimum. It is 4.5:1; large text needs 3:1.",
          "普通文本对比度至少为4.5：1；大号文本至少为3：1。",
          "正文要求4.5比1。大字体要求3.0∶1。"
        ],
        do: assert_named_facts!(text, @research_facts)

    for text <- [
          "Ordinary text needs 3:1; large text needs 4.5:1.",
          "普通文本对比度至少为3：1；大号文本至少为4.5：1。",
          "Normal text: large text needs 4.5:1 and 3:1.",
          "普通文本；大号文本需要4.5：1和3：1。",
          "普通文本有最低要求。阈值为4.5：1；大号文本需要3：1。"
        ] do
      assert_raise ExUnit.AssertionError, fn -> assert_named_facts!(text, @research_facts) end
    end
  end

  test "association distance counts characters and stays bounded in both directions" do
    for separator <- ["x", "字"] do
      for text <- [
            "ordinary" <> String.duplicate(separator, 160) <> "4.5:1; large 3:1",
            "4.5:1" <> String.duplicate(separator, 160) <> "ordinary; large 3:1"
          ],
          do: assert_named_facts!(text, @research_facts)

      for text <- [
            "ordinary" <> String.duplicate(separator, 161) <> "4.5:1; large 3:1",
            "4.5:1" <> String.duplicate(separator, 161) <> "ordinary; large 3:1"
          ] do
        assert_raise ExUnit.AssertionError, fn -> assert_named_facts!(text, @research_facts) end
      end
    end
  end

  test "a direct pronoun can continue the same named fact in the next sentence" do
    ordinary = "For ordinary-size body text, WCAG 2.2 SC 1.4.3 requires at least 4.5:1.\n\n"

    large =
      "Large text is treated more leniently because wider character strokes stay readable at lower contrast. It needs only 3:1, and is defined as 18pt regular or 14pt bold."

    assert_named_facts!(ordinary <> large, @research_facts)

    assert_named_facts!(
      "普通文本的对比度至少是4.5：1。大号文本因为笔画较宽而可以适用较低对比度。它只需3：1。",
      @research_facts
    )

    for text <- [
          String.replace(ordinary, "4.5:1", "3:1") <> String.replace(large, "3:1", "4.5:1"),
          ordinary <> "Large text differs. Ordinary text needs 3:1.",
          ordinary <> "Large text differs. A logo needs 3:1.",
          ordinary <> "Large text differs. The logo has thick strokes. It needs 3:1.",
          ordinary <> "Large text differs.\nIt needs 3:1.",
          "普通文本的对比度至少是4.5：1。大号文本有区别。标志只需3：1。",
          "普通文本的对比度至少是4.5：1。大号文本有区别。普通文本只需3：1。",
          "普通文本的对比度至少是4.5：1。大号文本有区别。标志有较宽的笔画。它只需3：1。"
        ] do
      assert_raise ExUnit.AssertionError, fn -> assert_named_facts!(text, @research_facts) end
    end
  end

  test "all expected words and numbers do not establish the requested sales facts" do
    facts = [{"Oak", "\\b240\\b"}, {"Pine", "\\b225\\b"}]
    assert_named_facts!("Oak: 240; Pine: 225; Combined: 465", facts)
    assert_named_facts!("240 from Oak, and 225 from Pine, giving 465.", facts)

    assert_raise ExUnit.AssertionError, fn ->
      assert_named_facts!("Oak: 225; Pine: 240; Combined: 465", facts)
    end
  end

  test "contrast thresholds must stay associated with the right text category" do
    facts = [{"ordinary|normal", "4\\.5:1"}, {"large", "(?<![\\d.])3:1"}]
    assert_named_facts!("Ordinary text needs 4.5:1; large text needs 3:1.", facts)
    assert_named_facts!("Use 4.5:1 for ordinary text and 3:1 for large text.", facts)

    assert_raise ExUnit.AssertionError, fn ->
      assert_named_facts!("Ordinary text needs 3:1; large text needs 4.5:1.", facts)
    end
  end
end
