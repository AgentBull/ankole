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

  @doc "Split source text into chunks each within `max_bytes` (default #{@default_max_bytes})."
  @spec split(String.t(), non_neg_integer()) :: [String.t()]
  def split(text, max_bytes \\ @default_max_bytes) when is_binary(text) do
    case byte_size(text) <= max_bytes do
      true -> [text]
      false -> split_by_bytes(text, max_bytes)
    end
  end

  # Chunks are byte-lossless slices: each line keeps its trailing newline, so
  # concatenating all chunks reproduces the text exactly (the sealed-prefix
  # math in the stream chain depends on this). Prefer line boundaries, then
  # grapheme boundaries, so a chunk never splits a UTF-8 codepoint.
  defp split_by_bytes(text, max_bytes) do
    text
    |> newline_units()
    |> Enum.reduce({[], ""}, fn unit, {chunks, current} ->
      candidate = current <> unit

      cond do
        byte_size(candidate) <= max_bytes ->
          {chunks, candidate}

        byte_size(unit) > max_bytes ->
          {chunks ++ flush(current) ++ split_long_line(unit, max_bytes), ""}

        true ->
          {chunks ++ flush(current), unit}
      end
    end)
    |> then(fn {chunks, current} -> chunks ++ flush(current) end)
    |> case do
      [] -> [""]
      chunks -> chunks
    end
  end

  defp newline_units(text) do
    case String.split(text, "\n", trim: false) do
      [only] ->
        [only]

      lines ->
        lines |> Enum.slice(0..-2//1) |> Enum.map(&(&1 <> "\n")) |> Kernel.++(last_unit(lines))
    end
  end

  defp last_unit(lines) do
    case List.last(lines) do
      "" -> []
      last -> [last]
    end
  end

  defp flush(""), do: []
  defp flush(chunk), do: [chunk]

  @doc """
  Whether `text` ends inside an unclosed ``` code fence.
  """
  @spec fence_open?(String.t()) :: boolean()
  def fence_open?(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.count(&fence_line?/1)
    |> rem(2) == 1
  end

  defp fence_line?(line), do: Regex.match?(~r/^\s{0,3}(```|~~~)/, line)

  @doc """
  Display form of one source chunk: reopens a fence the previous chunks left
  open and closes a fence this chunk leaves open. The source itself is never
  mutated — callers keep byte-exact slices for durable prefix math.
  """
  @spec display_chunk(String.t(), boolean()) :: String.t()
  def display_chunk(source, fence_open_before? \\ false) when is_binary(source) do
    displayed = if fence_open_before?, do: "```\n" <> source, else: source
    if fence_open?(displayed), do: displayed <> "\n```", else: displayed
  end

  @doc """
  Display forms for a whole chunk sequence, threading fence state across
  boundaries so every provider message renders closed fences.
  """
  @spec display_chunks([String.t()]) :: [String.t()]
  def display_chunks(chunks) when is_list(chunks) do
    chunks
    |> Enum.map_reduce(false, fn source, open_before? ->
      {display_chunk(source, open_before?),
       fence_open?(if(open_before?, do: "```\n", else: "") <> source)}
    end)
    |> elem(0)
  end

  defp split_long_line(line, max_bytes) do
    line
    |> String.graphemes()
    |> Enum.reduce({[], ""}, fn grapheme, {chunks, current} ->
      candidate = current <> grapheme

      if byte_size(candidate) > max_bytes do
        {chunks ++ [current], grapheme}
      else
        {chunks, candidate}
      end
    end)
    |> then(fn {chunks, current} -> chunks ++ flush(current) end)
  end

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
