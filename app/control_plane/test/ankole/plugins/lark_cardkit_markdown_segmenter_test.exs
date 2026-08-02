defmodule Ankole.Plugins.LarkAdapter.CardKitMarkdownSegmenterTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.LarkAdapter.CardKit.MarkdownSegmenter

  test "large Unicode Markdown is segmented without losing or reordering bytes" do
    paragraph = "## 市场复盘 📈\n\n能源链、半导体与现金流；emoji 👩🏽‍💻 保持完整。\n\n"
    markdown = String.duplicate(paragraph, 3_000)

    pages = MarkdownSegmenter.pages(markdown, max_bytes: 4_096)

    assert length(pages) > 50
    assert Enum.map_join(pages, & &1.source) == markdown
    assert hd(pages).start_byte == 0
    assert List.last(pages).end_byte == byte_size(markdown)

    assert Enum.chunk_every(pages, 2, 1, :discard)
           |> Enum.all?(fn [left, right] -> left.end_byte == right.start_byte end)

    assert Enum.all?(pages, &(byte_size(&1.content) <= 4_096))
  end

  test "an oversized fenced block is independently renderable on every card" do
    body = String.duplicate("IO.puts(\"长代码 👩🏽‍💻\")\n", 1_000)
    markdown = "````elixir\n" <> body <> "````\n"

    pages = MarkdownSegmenter.pages(markdown, max_bytes: 1_024)

    assert length(pages) > 1
    assert Enum.map_join(pages, & &1.source) == markdown

    assert Enum.all?(pages, fn page ->
             String.starts_with?(page.content, "````elixir\n") and
               Regex.scan(~r/````/, page.content) |> length() |> rem(2) == 0
           end)
  end

  test "normal links and remote images remain inside semantic blocks" do
    blocks = [
      "[设计文档](https://example.com/design?q=cardkit)\n\n",
      "![行情图](https://example.com/chart.png \"收盘\")\n\n",
      "结论：保持 CardKit 流式更新。\n"
    ]

    pages = MarkdownSegmenter.pages(Enum.join(blocks), max_bytes: 512)

    assert Enum.map_join(pages, & &1.source) == Enum.join(blocks)

    for block <- blocks do
      assert Enum.any?(pages, &String.contains?(&1.source, String.trim_trailing(block)))
    end
  end

  test "a long Markdown list rolls over between complete list items" do
    markdown =
      1..180
      |> Enum.map_join("\n", fn index ->
        "- 第#{index |> Integer.to_string() |> String.pad_leading(3, "0")}行：CardKit 超长文本分页、顺序与完整性验证。"
      end)

    pages = MarkdownSegmenter.pages(markdown, max_bytes: 12 * 1_024)

    assert length(pages) == 2
    assert Enum.map_join(pages, & &1.source) == markdown
    assert Enum.all?(Enum.drop(pages, 1), &String.starts_with?(&1.source, "- "))
    assert Enum.all?(Enum.drop(pages, -1), &String.ends_with?(&1.source, "\n"))
    refute Enum.any?(pages, &String.ends_with?(&1.source, "- "))
  end

  test "an empty answer still yields one valid Markdown element" do
    assert [%{source: "", content: " ", start_byte: 0, end_byte: 0}] =
             MarkdownSegmenter.pages("")
  end

  test "six Markdown tables below the byte budget split into table-budget pages" do
    table = "| Name | Value |\n| --- | --- |\n| A | 1 |\n\n"
    markdown = String.duplicate(table, 6)

    pages = MarkdownSegmenter.pages(markdown)

    assert length(pages) == 2
    assert Enum.map_join(pages, & &1.source) == markdown
    assert Enum.map(pages, &MarkdownSegmenter.count_tables(&1.content)) == [4, 2]
  end

  test "pipe rows inside a code fence never count as tables" do
    markdown = """
    ```text
    | Name | Value |
    | --- | --- |
    ```

    | Name | Value |
    | --- | --- |
    | A | 1 |
    """

    assert MarkdownSegmenter.count_tables(markdown) == 1
    assert length(MarkdownSegmenter.pages(markdown)) == 1
  end

  test "growing an answer never moves an earlier page boundary" do
    blocks =
      Enum.map(1..40, fn index ->
        case rem(index, 3) do
          0 -> "| K#{index} | V |\n| --- | --- |\n| a | #{index} |\n\n"
          1 -> "第 #{index} 段：分页边界必须只取决于答案前缀。\n\n"
          2 -> "```elixir\nIO.puts(#{index})\n```\n\n"
        end
      end)

    full_pages = MarkdownSegmenter.pages(Enum.join(blocks), max_bytes: 512)
    assert length(full_pages) > 2

    for cut <- 1..(length(blocks) - 1) do
      prefix = blocks |> Enum.take(cut) |> Enum.join()
      settled = MarkdownSegmenter.pages(prefix, max_bytes: 512) |> Enum.drop(-1)

      assert Enum.map(settled, & &1.source) ==
               full_pages |> Enum.take(length(settled)) |> Enum.map(& &1.source)
    end
  end
end
