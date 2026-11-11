defmodule Ankole.Brain.FileText do
  @moduledoc """
  Reads the structure that the kernel writes into a file page's extracted text.

  The kernel puts a marker line before each PDF page (`[Page N]`), each slide
  (`[Slide N]`), and each sheet (`[Sheet: name]`), replaces a DOCX or ODT
  heading with `[Section: outer > heading]`, and writes a table row as `R<row>`
  followed by tab-separated cells in column order. Brain chunks and learns
  each segment on its own, so every chunk and excerpt names the page, slide,
  sheet, or section it came from, and a table chunk starts with its header row.
  """

  # shortcut: a document line that itself reads `[Page 3]` starts a segment and
  # mislabels the text after it; switch to out-of-band spans if that shows up.
  @marker ~r/^\[(?:Page \d+|Slide \d+|Sheet: [^\]\n]+|Section: [^\n]+)\]\n/m
  @row ~r/^R\d+\t/
  @table_formats ~w(xlsx xlsm ods csv tsv)

  @doc "Whether the page is a spreadsheet or delimited file."
  def table?(%{file: %{"format" => format}}), do: format in @table_formats
  def table?(_page), do: false

  @doc "Splits extracted text into `{marker, text}` segments. Text before the first marker has no marker."
  @spec segments(String.t()) :: [{String.t() | nil, String.t()}]
  def segments(body) do
    [leading | marked] = Regex.split(@marker, body, include_captures: true)

    [{nil, leading} | marked |> Enum.chunk_every(2) |> Enum.map(&List.to_tuple/1)]
    |> Enum.map(fn {marker, text} -> {marker && String.trim_trailing(marker), text} end)
    |> Enum.reject(fn {_marker, text} -> String.trim(text) == "" end)
  end

  @doc """
  The lines that open every chunk of a segment: its marker and, for a table,
  its header row. The header is the first of the leading ten rows with at
  least two filled cells, which skips a title banner above the column names.
  """
  @spec chunk_header(String.t() | nil, String.t(), boolean()) :: [String.t()]
  def chunk_header(marker, text, table?) do
    Enum.reject([marker, table? && header_row(text)], &(&1 in [nil, false]))
  end

  @doc "Puts a segment's header lines above a chunk, without repeating a line the chunk starts with."
  @spec with_header(String.t(), [String.t()]) :: String.t()
  def with_header(chunk, header) do
    header
    |> Enum.reject(&String.starts_with?(chunk, &1))
    |> Enum.concat([chunk])
    |> Enum.join("\n")
  end

  @doc "Each sheet's marker, extracted row count, and leading rows."
  @spec table_outline(String.t()) :: [
          %{sheet: String.t() | nil, rows: non_neg_integer(), sample: [String.t()]}
        ]
  def table_outline(body) do
    Enum.map(segments(body), fn {marker, text} ->
      rows = text |> String.split("\n") |> Enum.filter(&(&1 =~ @row))
      %{sheet: marker, rows: length(rows), sample: Enum.take(rows, 10)}
    end)
  end

  defp header_row(text) do
    rows = text |> String.split("\n", parts: 11) |> Enum.take(10) |> Enum.filter(&(&1 =~ @row))

    Enum.find(rows, List.first(rows), fn row ->
      row |> String.split("\t") |> tl() |> Enum.count(&(&1 != "")) >= 2
    end)
  end
end
