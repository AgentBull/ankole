defmodule Ankole.Kernel.FileTextTest do
  use ExUnit.Case, async: true

  alias Ankole.Kernel

  test "classifies supported file formats and extracts UTF-8 and CSV text across the NIF boundary" do
    assert Kernel.file_extractor_version() >= 1
    assert {:ok, %{subtype: :text, format: "md"}} = Kernel.file_classify_format("guide.md")
    assert {:ok, %{subtype: :document, format: "pdf"}} = Kernel.file_classify_format("spec.pdf")
    assert :unsupported = Kernel.file_classify_format("diagram.png", "image/png")

    assert {:ok,
            %{
              status: :ok,
              subtype: :text,
              format: "csv",
              plain_text: "name\tamount\nAlpha\t42\n",
              metadata: %{"row_count" => 1, "delimiter" => ","},
              error: nil
            }} = Kernel.file_extract_text("name,amount\nAlpha,42\n", "metrics.csv", "text/csv")

    assert {:ok, %{status: :skipped, error: "unsupported_format"}} =
             Kernel.file_extract_text(<<137, 80, 78, 71>>, "logo.png", "image/png")
  end
end
