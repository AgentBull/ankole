defmodule Ankole.Kernel.SpreadsheetTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel

  @corpus Path.expand("../../fixtures/spreadsheet/corpus", __DIR__)

  defp set(sheet_id, cell, input),
    do: %{"type" => "cell.set", "sheet_id" => sheet_id, "cell" => cell, "input" => input}

  test "a blank workbook crosses the boundary as bytes, search text, and metadata" do
    assert {:ok,
            %{
              doc_ref: doc,
              bytes: "PK" <> _,
              plain_text: "[Sheet: Sheet1]\n",
              metadata: metadata
            }} =
             Kernel.office_create_blank(:spreadsheet, "预算")

    assert %{
             "sheets" => [%{"sheet_id" => 1, "name" => "Sheet1", "rows" => 0, "cols" => 0}],
             "has_unsupported_objects" => false,
             "truncated" => false
           } = metadata

    assert {:ok, %{doc_ref: edited, committed_op: committed, structural_edit: nil}} =
             Kernel.office_apply(doc, set(1, "A1", "季度预算"), [], nil)

    assert committed == set(1, "A1", "季度预算")

    assert {:ok, %{plain_text: "[Sheet: Sheet1]\nR1\t季度预算\n"}} =
             Kernel.office_export(edited)

    assert {:ok, %{plain_text: "[Sheet: Sheet1]\n"}} = Kernel.office_export(doc)
  end

  test "opening replays committed tail operations and keeps the file's sheet ids" do
    bytes = File.read!(Path.join(@corpus, "24_多币种结算.xlsx"))
    tail = [%{"type" => "sheet.insert", "sheet_id" => 3, "name" => "附表", "index" => 1}]

    assert {:ok, %{doc_ref: doc, plain_text: plain_text, metadata: metadata}} =
             Kernel.office_open(:spreadsheet, bytes, tail)

    assert plain_text =~ "结算台账"

    assert [
             %{"sheet_id" => 1, "name" => "结算台账"},
             %{"sheet_id" => 3, "name" => "附表"},
             %{"sheet_id" => 2, "name" => "汇率假设"}
           ] = metadata["sheets"]

    assert {:ok, %{bytes: xlsx}} = Kernel.office_export(doc)

    assert {:ok, %{metadata: %{"sheets" => [_, %{"sheet_id" => 3}, %{"sheet_id" => 2}]}}} =
             Kernel.office_open(:spreadsheet, xlsx, [])
  end

  test "structural edits rebase in-flight operations or reject them as conflicts" do
    {:ok, %{doc_ref: doc}} = Kernel.office_create_blank(:spreadsheet, "Rebase")

    insert = %{
      "type" => "line.insert",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 2,
      "count" => 3
    }

    assert {:ok, %{doc_ref: doc, committed_op: insert, structural_edit: edit}} =
             Kernel.office_apply(doc, insert, [], nil)

    assert edit == %{
             "kind" => "insert_lines",
             "sheet_id" => 1,
             "axis" => "rows",
             "at" => 2,
             "count" => 3
           }

    assert {:ok, %{committed_op: %{"cell" => "C8", "input" => "=SUM(B1:B8)"}}} =
             Kernel.office_apply(doc, set(1, "C5", "=SUM(B1:B5)"), [insert], nil)

    delete = %{
      "type" => "line.delete",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 0,
      "count" => 4
    }

    {:ok, %{doc_ref: doc, committed_op: delete}} = Kernel.office_apply(doc, delete, [], nil)

    assert {:conflict, :target_deleted} =
             Kernel.office_apply(doc, set(1, "A2", "x"), [delete], nil)
  end

  test "invalid input is an error, not a crash" do
    {:ok, %{doc_ref: doc}} = Kernel.office_create_blank(:spreadsheet, "Errors")
    assert {:error, reason} = Kernel.office_apply(doc, %{"type" => "cell.select"}, [], nil)
    assert reason =~ "invalid operation"
    assert {:error, reason} = Kernel.office_apply(doc, set(9, "A1", "1"), [], nil)
    assert reason =~ "sheet_id 9"
    assert {:error, reason} = Kernel.office_open(:spreadsheet, "not a zip", [])
    assert reason =~ "could not be read"
  end
end
