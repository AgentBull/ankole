defmodule Ankole.PdfFixture do
  @moduledoc "Builds minimal PDFs for file extraction tests."

  @doc """
  A PDF with one page per entry. A page shows its text, and a page with `""`
  has no text layer, as a scanned page does.
  """
  @spec pdf([String.t()]) :: binary()
  def pdf(pages) do
    kids = Enum.map_join(1..length(pages), " ", &"#{2 + &1 * 2} 0 R")

    page_objects =
      pages
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {text, number} ->
        content = if text == "", do: "", else: "BT /F1 12 Tf (#{text}) Tj ET"

        [
          "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] " <>
            "/Resources << /Font << /F1 3 0 R >> >> /Contents #{3 + number * 2} 0 R >>",
          "<< /Length #{byte_size(content)} >>\nstream\n#{content}\nendstream"
        ]
      end)

    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [#{kids}] /Count #{length(pages)} >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
      | page_objects
    ]

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({"%PDF-1.4\n", []}, fn {object, number}, {body, offsets} ->
        {body <> "#{number} 0 obj\n#{object}\nendobj\n", [byte_size(body) | offsets]}
      end)

    entries =
      offsets
      |> Enum.reverse()
      |> Enum.map_join(&(String.pad_leading("#{&1}", 10, "0") <> " 00000 n \n"))

    size = length(objects) + 1

    body <>
      "xref\n0 #{size}\n0000000000 65535 f \n#{entries}" <>
      "trailer\n<< /Size #{size} /Root 1 0 R >>\nstartxref\n#{byte_size(body)}\n%%EOF\n"
  end
end
