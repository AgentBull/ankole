defmodule Ankole.Plugins.WeComAdapterMarkdownTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.WeComAdapter.Markdown

  test "tables pass through untouched (WeCom renders them natively)" do
    table = "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
    assert Markdown.to_wecom(table) == table
  end

  test "images degrade to labelled links and task lists flatten" do
    assert Markdown.to_wecom("看这张 ![架构图](https://x/y.png) 就懂了") ==
             "看这张 [图片: 架构图](https://x/y.png) 就懂了"

    assert Markdown.to_wecom("![](https://x/y.png)") == "[图片](https://x/y.png)"
    assert Markdown.to_wecom("- [x] done\n- [ ] todo") == "- done\n- todo"
  end

  test "html tags strip to their text" do
    assert Markdown.to_wecom("a <b>bold</b> move") == "a bold move"
  end

  test "split is byte-lossless and prefix-stable under growth" do
    text = Enum.map_join(1..200, "\n", &"line #{&1} #{String.duplicate("x", 80)}")
    chunks = Markdown.split(text, 2_000)
    assert length(chunks) > 1
    assert Enum.join(chunks, "") == text
    assert Enum.all?(chunks, &(byte_size(&1) <= 2_000))

    grown_chunks = Markdown.split(text <> "\nmore", 2_000)
    assert Enum.take(grown_chunks, length(chunks) - 1) == Enum.take(chunks, length(chunks) - 1)
  end

  test "display chunks close and reopen code fences across boundaries" do
    text = "before\n```elixir\n" <> String.duplicate("code line\n", 40) <> "```\nafter"
    chunks = Markdown.split(text, 200)
    displays = Markdown.display_chunks(chunks)

    assert length(displays) > 1
    assert Enum.all?(displays, fn display -> not Markdown.fence_open?(display) end)
    # Sources stay byte-exact even though displays add fence markers.
    assert Enum.join(chunks, "") == text
  end
end
