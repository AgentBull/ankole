defmodule Ankole.Kernel.RepairGeneratedMarkdownTest do
  use ExUnit.Case, async: true

  alias Ankole.Plugins.LarkAdapter.CardKit.CardChain
  alias Ankole.Plugins.LarkAdapter.CardKit.Renderer

  @golden_path Path.expand(
                 "../../fixtures/generated_markdown_repair_cases.json",
                 __DIR__
               )

  test "Ankole.Kernel.repair_generated_markdown/1 matches shared golden corpus and is idempotent" do
    cases = @golden_path |> File.read!() |> Ankole.JSON.decode!()
    assert cases != []

    for %{"name" => name, "input" => input, "expected" => expected} <- cases do
      repaired = Ankole.Kernel.repair_generated_markdown(input)

      assert repaired == expected,
             "case #{inspect(name)} mismatch:\n  got:      #{inspect(repaired)}\n  expected: #{inspect(expected)}"

      assert Ankole.Kernel.repair_generated_markdown(repaired) == repaired,
             "case #{inspect(name)} is not idempotent"
    end
  end

  test "Lark CardKit keeps page.source raw monotonic bytes while repairing rendered answer content" do
    raw = "结论：\\n\\n- **金额： **203\\n- 误差 ~50%~ 对比 ~~旧方案~~，公式 $\\nabla \\cdot E \\neq 0$"
    pages = CardChain.pages(raw)

    assert Enum.map_join(pages, & &1.source) == raw
    [page] = pages
    assert page.source == raw

    {:ok, card} =
      Renderer.render(
        %{"state" => "completed", "answer" => raw},
        CardChain.page_opts(page, 0, 1, true) ++ [mode: :terminal]
      )

    content = Renderer.card_answer_content(card)
    assert content =~ "\n\n- **金额：** 203"
    assert content =~ "\\~50%\\~"
    assert content =~ "~~旧方案~~"
    assert content =~ "$\\nabla \\cdot E \\neq 0$"
  end

  test "plain-text channels unescape \\~ in prose while keeping code spans verbatim" do
    repaired =
      Ankole.Kernel.repair_generated_markdown("误差 ~50%~，代码 `foo\\~bar` 保持不变")

    assert repaired =~ "\\~50%\\~"
    plain = Ankole.Plugins.MarkdownChunks.unescape_plain_tildes(repaired)
    assert plain == "误差 ~50%~，代码 `foo\\~bar` 保持不变"
  end
end
