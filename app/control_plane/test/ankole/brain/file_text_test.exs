defmodule Ankole.Brain.FileTextTest do
  use ExUnit.Case, async: true

  alias Ankole.Brain.FileText

  test "splits extracted text at page, slide, and sheet markers" do
    body = "Cover note\n[Page 1]\nIntro\n[Page 2]\n\n[Page 3]\nTerms [Page 9] inline\n"

    assert FileText.segments(body) == [
             {nil, "Cover note\n"},
             {"[Page 1]", "Intro\n"},
             {"[Page 3]", "Terms [Page 9] inline\n"}
           ]

    assert FileText.segments("[Slide 2]\nRoadmap\n[Sheet: 预算 2026]\nR1\tA\n") == [
             {"[Slide 2]", "Roadmap\n"},
             {"[Sheet: 预算 2026]", "R1\tA\n"}
           ]

    assert FileText.segments("Title\n[Section: Terms > Breach [late]]\nPay 1%.\n") == [
             {nil, "Title\n"},
             {"[Section: Terms > Breach [late]]", "Pay 1%.\n"}
           ]

    assert FileText.segments("") == []
  end

  test "a table chunk opens with its sheet and the header row below a title banner" do
    sheet = "R1\t2026 年销售报表\nR2\t地区\t产品\t营收\nR3\t华东\t旗舰版\t1,250,000\n"
    header = FileText.chunk_header("[Sheet: 销售]", sheet, true)

    assert header == ["[Sheet: 销售]", "R2\t地区\t产品\t营收"]

    assert FileText.with_header("R40\t华南\t标准版\t9,000", header) ==
             "[Sheet: 销售]\nR2\t地区\t产品\t营收\nR40\t华南\t标准版\t9,000"

    # The chunk that already starts with the header row does not repeat it.
    assert FileText.with_header("R2\t地区\t产品\t营收\nR3\t华东", header) ==
             "[Sheet: 销售]\nR2\t地区\t产品\t营收\nR3\t华东"
  end

  test "a document chunk opens with its marker only, and unmarked text stays as it is" do
    assert FileText.chunk_header("[Page 4]", "R1\tlooks\tlike a row\n", false) == ["[Page 4]"]
    assert FileText.chunk_header(nil, "plain notes", false) == []
    assert FileText.with_header("plain notes", []) == "plain notes"
  end

  test "a single-column table falls back to its first row as the header" do
    assert FileText.chunk_header(nil, "R1\tname\nR2\tAda\n", true) == ["R1\tname"]
    assert FileText.chunk_header(nil, "free text without rows", true) == []
  end

  test "outlines each sheet by its extracted row count and leading rows" do
    rows = Enum.map_join(1..12, "\n", &"R#{&1}\tv#{&1}")
    body = "[Sheet: A]\n#{rows}\na comment line\n[Sheet: B]\nR5\tx\ty\n"

    assert [
             %{sheet: "[Sheet: A]", rows: 12, sample: sample},
             %{sheet: "[Sheet: B]", rows: 1, sample: ["R5\tx\ty"]}
           ] = FileText.table_outline(body)

    assert length(sample) == 10
    assert List.last(sample) == "R10\tv10"
  end

  test "recognises table files by their cached format" do
    assert FileText.table?(%{file: %{"format" => "xlsx"}})
    assert FileText.table?(%{file: %{"format" => "tsv"}})
    refute FileText.table?(%{file: %{"format" => "pdf"}})
    refute FileText.table?(%{file: nil})
  end
end
