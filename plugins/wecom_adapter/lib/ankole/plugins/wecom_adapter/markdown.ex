defmodule Ankole.Plugins.WeComAdapter.Markdown do
  @moduledoc """
  Deterministic degrade of standard Markdown to WeCom's Markdown subset, plus a
  byte-budget splitter for the 20480-byte message cap.

  WeCom AI-bot Markdown supports headings, bold, lists, quotes, links, code,
  and tables (wider than DingTalk). Image syntax is not documented as
  supported, so images degrade to a labelled link; task-list checkboxes become
  plain list items and raw HTML tags are stripped to their text. Inbound text
  is never reverse-converted.

  Splitting is greedy on line boundaries, so chunk boundaries are prefix-stable
  under append-only growth — an earlier chunk never changes when text is added.
  Chunks are byte-exact source slices; when a boundary falls inside a code
  fence, only the *display* form closes and reopens the fence
  (`display_chunk/2`), keeping durable source math lossless.
  """

  # Stream/markdown content caps at 20480 bytes; keep a conservative source
  # budget so the status line, quote blocks, and JSON escaping have headroom.
  @default_max_bytes 14_000

  @doc "Source budget used by reply paging."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc "Degrade standard Markdown into WeCom's supported subset."
  @spec to_wecom(String.t()) :: String.t()
  def to_wecom(text) when is_binary(text) do
    text
    |> degrade_images()
    |> degrade_task_lists()
    |> strip_html_tags()
  end

  def to_wecom(_text), do: ""

  def split(text, max_bytes \\ @default_max_bytes),
    do: Ankole.Plugins.MarkdownChunks.split(text, max_bytes)

  defdelegate fence_open?(text), to: Ankole.Plugins.MarkdownChunks

  defdelegate display_chunk(source, fence_open_before? \\ false),
    to: Ankole.Plugins.MarkdownChunks

  defdelegate display_chunks(chunks), to: Ankole.Plugins.MarkdownChunks

  # `![alt](url)` → `[图片: alt](url)` — the link renders everywhere while
  # image support in bot Markdown stays unverified.
  defp degrade_images(text) do
    Regex.replace(~r/!\[([^\]]*)\]\(([^)\s]+)[^)]*\)/, text, fn _match, alt, url ->
      label = if alt == "", do: "图片", else: "图片: #{alt}"
      "[#{label}](#{url})"
    end)
  end

  defp degrade_task_lists(text) do
    Regex.replace(~r/(^\s*[-*+] )\[[ xX]\]\s+/m, text, "\\1")
  end

  defp strip_html_tags(text) do
    Regex.replace(~r/<\/?[a-zA-Z][^>]*>/, text, "")
  end
end
