defmodule Ankole.Plugins.DingTalkAdapter.Markdown do
  import Ankole.Plugins.MarkdownChunks, only: [strip_html_tags: 2, degrade_task_lists: 1]

  @moduledoc """
  Deterministic degrade of standard Markdown to DingTalk's Markdown subset, plus
  a byte-budget splitter for the `msgParam` limit.

  DingTalk's `sampleMarkdown` supports headings, bold/italic, ordered/unordered
  lists, links, images, inline code, code fences, and quotes. Unsupported
  elements degrade predictably: tables become fenced code blocks (shape
  preserved), task-list checkboxes become plain list items, and raw HTML tags are
  stripped to their text. Inbound text is never reverse-converted.

  Splitting is greedy on line boundaries, so chunk boundaries are prefix-stable
  under append-only growth — an earlier chunk never changes when text is added.
  Chunks are byte-exact source slices; when a boundary falls inside a code
  fence, only the *display* form closes and reopens the fence
  (`display_chunk/2`), keeping durable source math lossless.
  Code spans keep the exact source bytes. These rules apply to prose.
  """

  # msgParam caps at 15000 bytes; keep a conservative source budget so JSON
  # escaping and template fields have headroom.
  @default_max_bytes 10_000

  @doc "Whether text carries any Markdown formatting (→ sampleMarkdown vs sampleText)."
  @spec formatted?(String.t()) :: boolean()
  def formatted?(text) when is_binary(text) do
    Regex.match?(
      ~r/(^|\n)\s{0,3}(#|[-*+] |\d+\. |>)|[*_`~]|\[.+\]\(.+\)|\!\[.*\]\(.+\)|```/u,
      text
    )
  end

  def formatted?(_text), do: false

  @doc "Degrade standard Markdown into DingTalk's supported subset."
  @spec to_dingtalk(String.t()) :: String.t()
  def to_dingtalk(text) when is_binary(text) do
    Ankole.Plugins.MarkdownChunks.rewrite_prose(text, fn source, marker ->
      source
      |> degrade_tables()
      |> degrade_task_lists()
      |> strip_html_tags(marker)
    end)
  end

  def to_dingtalk(_text), do: ""

  def split(text, max_bytes \\ @default_max_bytes),
    do: Ankole.Plugins.MarkdownChunks.split(text, max_bytes)

  defdelegate fence_open?(text), to: Ankole.Plugins.MarkdownChunks

  defdelegate display_chunk(source, fence_open_before? \\ false),
    to: Ankole.Plugins.MarkdownChunks

  defdelegate display_chunks(chunks), to: Ankole.Plugins.MarkdownChunks

  # A GitHub-style table (header row + separator row of dashes) is wrapped in a
  # fenced code block so alignment survives even though DingTalk has no table.
  defp degrade_tables(text) do
    Regex.replace(
      ~r/(?:^\|.*\|\s*\n)(?:^\|[\s:\-|]+\|\s*\n)(?:^\|.*\|\s*\n?)+/m,
      text,
      fn table -> "```\n" <> String.trim_trailing(table) <> "\n```\n" end
    )
  end
end
