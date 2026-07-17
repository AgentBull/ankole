defmodule Ankole.Plugins.DingTalkAdapterMarkdownTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.DingTalkAdapter.Markdown

  test "formatted? detects Markdown syntax and plain text" do
    assert Markdown.formatted?("# Heading")
    assert Markdown.formatted?("- item")
    assert Markdown.formatted?("**bold**")
    assert Markdown.formatted?("see [link](https://x)")
    assert Markdown.formatted?("```\ncode\n```")
    refute Markdown.formatted?("just a plain sentence")
  end

  test "split is byte-lossless on line boundaries within the budget" do
    text = String.duplicate("a", 30) <> "\n" <> String.duplicate("b", 30)
    assert [chunk1, chunk2] = Markdown.split(text, 40)
    # Each line keeps its trailing newline so concatenation reproduces the
    # source exactly — the AI-card sealed-prefix math depends on it.
    assert chunk1 == String.duplicate("a", 30) <> "\n"
    assert chunk2 == String.duplicate("b", 30)
    assert chunk1 <> chunk2 == text
    assert Enum.all?([chunk1, chunk2], &(byte_size(&1) <= 40))
  end

  test "display closes and reopens code fences across chunk boundaries" do
    text = "intro\n```\n" <> String.duplicate("code line\n", 6) <> "```"
    chunks = Markdown.split(text, 30)
    assert IO.iodata_to_binary(chunks) == text

    displays = Markdown.display_chunks(chunks)
    assert length(displays) == length(chunks)

    # Every displayed chunk renders with balanced fences.
    refute Enum.any?(displays, &Markdown.fence_open?/1)
    # A continuation chunk inside the fence reopens it for display.
    assert displays |> Enum.drop(1) |> Enum.any?(&String.starts_with?(&1, "```\n"))
  end

  test "split never breaks a multibyte grapheme mid-codepoint" do
    text = String.duplicate("中", 20)
    chunks = Markdown.split(text, 10)
    assert Enum.all?(chunks, &String.valid?/1)
    assert IO.iodata_to_binary(chunks) == text
    assert Enum.all?(chunks, &(byte_size(&1) <= 10))
  end

  test "split returns the whole text when within budget" do
    assert Markdown.split("short", 100) == ["short"]
  end

  test "degrade wraps GitHub tables in a fenced code block" do
    table = "| a | b |\n| - | - |\n| 1 | 2 |\n"
    result = Markdown.to_dingtalk(table)
    assert result =~ "```"
    assert result =~ "| a | b |"
  end

  test "degrade turns task-list checkboxes into plain list items and strips html" do
    assert Markdown.to_dingtalk("- [x] done\n- [ ] todo") == "- done\n- todo"
    assert Markdown.to_dingtalk("keep <b>bold</b> text") == "keep bold text"
  end
end
