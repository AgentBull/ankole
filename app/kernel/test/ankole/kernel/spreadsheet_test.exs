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
              xlsx_bytes: "PK" <> _,
              plain_text: "[Sheet: Sheet1]\n",
              metadata: metadata
            }} =
             Kernel.spreadsheet_create_blank("预算")

    assert %{
             "sheets" => [%{"sheet_id" => 1, "name" => "Sheet1", "rows" => 0, "cols" => 0}],
             "has_unsupported_objects" => false,
             "truncated" => false
           } = metadata

    assert {:ok, %{doc_ref: edited, committed_op: committed, structural_edit: nil}} =
             Kernel.spreadsheet_apply(doc, set(1, "A1", "季度预算"), [])

    assert committed == set(1, "A1", "季度预算")

    assert {:ok, %{plain_text: "[Sheet: Sheet1]\nR1\t季度预算\n"}} =
             Kernel.spreadsheet_export_xlsx(edited)

    assert {:ok, %{plain_text: "[Sheet: Sheet1]\n"}} = Kernel.spreadsheet_export_xlsx(doc)
  end

  test "opening replays committed tail operations and keeps the file's sheet ids" do
    bytes = File.read!(Path.join(@corpus, "24_多币种结算.xlsx"))
    tail = [%{"type" => "sheet.insert", "sheet_id" => 3, "name" => "附表", "index" => 1}]

    assert {:ok, %{doc_ref: doc, plain_text: plain_text, metadata: metadata}} =
             Kernel.spreadsheet_open(bytes, tail)

    assert plain_text =~ "结算台账"

    assert [
             %{"sheet_id" => 1, "name" => "结算台账"},
             %{"sheet_id" => 3, "name" => "附表"},
             %{"sheet_id" => 2, "name" => "汇率假设"}
           ] = metadata["sheets"]

    assert {:ok, %{xlsx_bytes: xlsx}} = Kernel.spreadsheet_export_xlsx(doc)

    assert {:ok, %{metadata: %{"sheets" => [_, %{"sheet_id" => 3}, %{"sheet_id" => 2}]}}} =
             Kernel.spreadsheet_open(xlsx, [])
  end

  test "structural edits rebase in-flight operations or reject them as conflicts" do
    {:ok, %{doc_ref: doc}} = Kernel.spreadsheet_create_blank("Rebase")

    insert = %{
      "type" => "line.insert",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 2,
      "count" => 3
    }

    assert {:ok, %{doc_ref: doc, committed_op: insert, structural_edit: edit}} =
             Kernel.spreadsheet_apply(doc, insert, [])

    assert edit == %{
             "kind" => "insert_lines",
             "sheet_id" => 1,
             "axis" => "rows",
             "at" => 2,
             "count" => 3
           }

    assert {:ok, %{committed_op: %{"cell" => "C8", "input" => "=SUM(B1:B8)"}}} =
             Kernel.spreadsheet_apply(doc, set(1, "C5", "=SUM(B1:B5)"), [insert])

    delete = %{
      "type" => "line.delete",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 0,
      "count" => 4
    }

    {:ok, %{doc_ref: doc, committed_op: delete}} = Kernel.spreadsheet_apply(doc, delete, [])

    assert {:conflict, :target_deleted} =
             Kernel.spreadsheet_apply(doc, set(1, "A2", "x"), [delete])
  end

  test "invalid input is an error, not a crash" do
    {:ok, %{doc_ref: doc}} = Kernel.spreadsheet_create_blank("Errors")
    assert {:error, reason} = Kernel.spreadsheet_apply(doc, %{"type" => "cell.select"}, [])
    assert reason =~ "invalid operation"
    assert {:error, reason} = Kernel.spreadsheet_apply(doc, set(9, "A1", "1"), [])
    assert reason =~ "sheet_id 9"
    assert {:error, reason} = Kernel.spreadsheet_open("not a zip", [])
    assert reason =~ "could not be read"
  end
end
