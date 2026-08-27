defmodule Ankole.Brain.MarkdocTest do
  use ExUnit.Case, async: true

  alias Ankole.Brain.Markdoc

  @body """
  # 明湖 AI

  公开资料和世界知识。

  {% audience scope="group:company_123" %}
  公司内部对明湖 AI 的共同认识。
  {% /audience %}

  {% audience scope="group:dept_sales" %}销售团队掌握的交易进展。{% /audience %}

  {% audience scope="principal:user_456" %}
  只针对这个人的背景补充。
  {% /audience %}

  参考 [[companies/acme]] 与 [[people/zhang-san]]。
  """

  describe "segments/1" do
    test "splits body into world and scoped segments in order" do
      assert {:ok, segments} = Markdoc.segments(@body)

      assert Enum.map(segments, & &1.scope) == [
               "world",
               "group:company_123",
               "group:dept_sales",
               "principal:user_456",
               "world"
             ]

      assert String.contains?(Enum.at(segments, 0).text, "公开资料")
      assert String.contains?(Enum.at(segments, 1).text, "共同认识")
      assert Enum.at(segments, 2).text == "销售团队掌握的交易进展。"
      assert String.contains?(Enum.at(segments, 4).text, "参考")
    end

    test "plain body is one world segment" do
      assert {:ok, [%{scope: "world", text: "plain text"}]} = Markdoc.segments("plain text")
    end

    test "rejects nested audience tags" do
      body = """
      {% audience scope="world" %}
      {% audience scope="group:a" %}x{% /audience %}
      {% /audience %}
      """

      assert {:error, :nested_audience_tag} = Markdoc.segments(body)
    end

    test "rejects unclosed and unopened tags" do
      assert {:error, :unclosed_audience_tag} =
               Markdoc.segments(~s({% audience scope="world" %}open))

      assert {:error, :unopened_audience_tag} = Markdoc.segments("text {% /audience %}")
    end

    test "rejects malformed scope values" do
      assert {:error, {:invalid_audience_scope, "team:x"}} =
               Markdoc.segments(~s({% audience scope="team:x" %}x{% /audience %}))
    end
  end

  describe "prune/2" do
    test "removes inaccessible segments and keeps original order" do
      keep = fn scope -> scope in ["world", "group:dept_sales"] end

      assert {:ok, pruned} = Markdoc.prune(@body, keep)

      assert String.contains?(pruned, "公开资料")
      assert String.contains?(pruned, "销售团队掌握的交易进展。")
      refute String.contains?(pruned, "共同认识")
      refute String.contains?(pruned, "背景补充")

      # Original order: world head before the sales block, tail after it.
      head = :binary.match(pruned, "公开资料") |> elem(0)
      sales = :binary.match(pruned, "销售团队") |> elem(0)
      tail = :binary.match(pruned, "参考") |> elem(0)
      assert head < sales and sales < tail
    end
  end

  describe "wikilinks/1" do
    test "extracts deduplicated slugs in order" do
      assert Markdoc.wikilinks(@body <> "\n再看 [[companies/acme]]") ==
               ["companies/acme", "people/zhang-san"]
    end
  end
end
