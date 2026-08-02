defmodule Ankole.Plugins.LarkAdapter.CardKit.MarkdownSegmenter do
  @moduledoc """
  Splits one Markdown answer into provider-sized, lossless CardKit pages.

  `source` is durable truth: concatenating every page always reconstructs the
  input byte-for-byte. `content` is the independently renderable Markdown for
  one card, so an oversized fenced block may receive display-only closing and
  reopening fences without changing `source`.

  Page boundaries are a pure function of the answer prefix: text appended to
  the answer never moves an earlier boundary. Sealed cards rely on this
  invariant while an answer streams.
  """

  @default_max_bytes 12 * 1_024
  @minimum_max_bytes 512
  # Feishu renders at most four Markdown tables in one rich-text element, so
  # one page never packs more than four tables.
  @default_max_tables 4

  @type page :: %{
          source: String.t(),
          content: String.t(),
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer()
        }

  @spec pages(String.t(), keyword()) :: [page()]
  def pages(text, opts \\ []) when is_binary(text) do
    max_bytes = max(Keyword.get(opts, :max_bytes, @default_max_bytes), @minimum_max_bytes)
    max_tables = max(Keyword.get(opts, :max_tables, @default_max_tables), 1)

    segments =
      text
      |> markdown_blocks()
      |> Enum.flat_map(&split_oversized_block(&1, max_bytes))
      |> pack_segments(max_bytes, max_tables)

    segments = if segments == [], do: [%{source: "", content: " "}], else: segments

    {pages, _offset} =
      Enum.map_reduce(segments, 0, fn segment, offset ->
        end_offset = offset + byte_size(segment.source)

        {%{
           source: segment.source,
           content: non_empty_content(segment.content),
           start_byte: offset,
           end_byte: end_offset
         }, end_offset}
      end)

    pages
  end

  @doc """
  Counts Markdown pipe tables in `text`.

  A table is one delimiter row (for example `| --- | --- |`) that directly
  follows a line that contains `|`. Lines inside fenced code never count.
  Pathological adjacent tables can count higher than a Markdown parser
  reports; that direction is safe because it splits pages earlier and trips
  the renderer budget instead of the provider.
  """
  @spec count_tables(String.t()) :: non_neg_integer()
  def count_tables(text) when is_binary(text) do
    text
    |> lines_with_endings()
    |> Enum.reduce({0, nil, false}, fn line, {count, fence, header?} ->
      next_fence = fence_transition(line, fence)

      cond do
        not is_nil(fence) or not is_nil(next_fence) ->
          {count, next_fence, false}

        header? and delimiter_row?(line) ->
          {count + 1, next_fence, false}

        true ->
          {count, next_fence, String.contains?(line, "|")}
      end
    end)
    |> elem(0)
  end

  defp delimiter_row?(line) do
    trimmed = String.trim(line)

    trimmed != "" and String.contains?(trimmed, "|") and String.contains?(trimmed, "-") and
      Regex.match?(~r/^[|:\-\s]+$/u, trimmed)
  end

  defp markdown_blocks(""), do: []

  defp markdown_blocks(text) do
    text
    |> lines_with_endings()
    |> Enum.reduce({[], [], nil}, fn line, {blocks, current, fence} ->
      next_fence = fence_transition(line, fence)
      current = [line | current]

      if block_boundary?(line, fence, next_fence) do
        {[current |> Enum.reverse() |> IO.iodata_to_binary() | blocks], [], next_fence}
      else
        {blocks, current, next_fence}
      end
    end)
    |> then(fn {blocks, current, _fence} ->
      blocks =
        if current == [],
          do: blocks,
          else: [current |> Enum.reverse() |> IO.iodata_to_binary() | blocks]

      Enum.reverse(blocks)
    end)
  end

  defp lines_with_endings(text) do
    parts = String.split(text, "\n", trim: false)
    last_index = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"", ^last_index} -> []
      {part, ^last_index} -> [part]
      {part, _index} -> [part <> "\n"]
    end)
  end

  defp fence_transition(line, nil) do
    case fence_open(line) do
      {marker, _opening} -> marker
      nil -> nil
    end
  end

  defp fence_transition(line, marker) do
    if fence_close?(line, marker), do: nil, else: marker
  end

  defp block_boundary?(_line, marker, marker) when not is_nil(marker), do: false
  defp block_boundary?(_line, marker, nil) when not is_nil(marker), do: true
  defp block_boundary?(line, nil, nil), do: String.trim(line) == ""
  defp block_boundary?(_line, nil, _opened_fence), do: false

  defp split_oversized_block(block, max_bytes) when byte_size(block) <= max_bytes,
    do: [%{source: block, content: block}]

  defp split_oversized_block(block, max_bytes) do
    case fenced_block(block) do
      {:ok, opening, body, closing} -> split_fenced_block(opening, body, closing, max_bytes)
      :error -> block |> split_plain(max_bytes) |> Enum.map(&%{source: &1, content: &1})
    end
  end

  defp fenced_block(block) do
    case lines_with_endings(block) do
      [opening | rest] ->
        case fence_open(opening) do
          {marker, _opening} ->
            case Enum.split(rest, max(length(rest) - 1, 0)) do
              {body, [closing]} ->
                if fence_close?(closing, marker) do
                  {:ok, opening, IO.iodata_to_binary(body), closing}
                else
                  {:ok, opening, IO.iodata_to_binary(rest), nil}
                end

              {_body, []} ->
                {:ok, opening, "", nil}
            end

          nil ->
            :error
        end

      _lines ->
        :error
    end
  end

  defp split_fenced_block(opening, body, closing, max_bytes) do
    {marker, _opening} = fence_open(opening)
    display_close = "\n" <> marker
    display_open = ensure_trailing_newline(opening)
    body_budget = max(max_bytes - byte_size(display_open) - byte_size(display_close), 64)
    body_chunks = split_plain(body, body_budget)
    body_chunks = if body_chunks == [], do: [""], else: body_chunks
    last_index = length(body_chunks) - 1

    body_chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      first? = index == 0
      last? = index == last_index

      source =
        [if(first?, do: opening, else: ""), chunk, if(last?, do: closing || "", else: "")]
        |> IO.iodata_to_binary()

      content =
        [
          if(first?, do: opening, else: display_open),
          chunk,
          if(last? and is_binary(closing), do: closing, else: display_close)
        ]
        |> IO.iodata_to_binary()

      %{source: source, content: content}
    end)
  end

  defp split_plain("", _max_bytes), do: []

  defp split_plain(text, max_bytes) do
    do_split_plain(text, max_bytes, [])
  end

  defp do_split_plain("", _max_bytes, chunks), do: Enum.reverse(chunks)

  defp do_split_plain(text, max_bytes, chunks) do
    {chunk, rest} = safe_prefix(text, max_bytes)
    do_split_plain(rest, max_bytes, [chunk | chunks])
  end

  defp safe_prefix(text, max_bytes) when byte_size(text) <= max_bytes, do: {text, ""}

  defp safe_prefix(text, max_bytes) do
    {prefix, rest} = grapheme_prefix(text, max_bytes)

    case preferred_break(prefix) do
      nil ->
        {prefix, rest}

      break_bytes ->
        {binary_part(text, 0, break_bytes),
         binary_part(text, break_bytes, byte_size(text) - break_bytes)}
    end
  end

  defp grapheme_prefix(text, max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {parts, bytes} ->
      next_bytes = bytes + byte_size(grapheme)

      if next_bytes > max_bytes and parts != [] do
        {:halt, {parts, bytes}}
      else
        {:cont, {[grapheme | parts], next_bytes}}
      end
    end)
    |> then(fn {parts, bytes} ->
      prefix = parts |> Enum.reverse() |> IO.iodata_to_binary()
      {prefix, binary_part(text, bytes, byte_size(text) - bytes)}
    end)
  end

  defp preferred_break(prefix) do
    minimum_break = div(byte_size(prefix), 2)

    line_breaks =
      Regex.scan(~r/\n/u, prefix, return: :index)
      |> Enum.map(fn [{start, length}] -> start + length end)
      |> Enum.filter(&(&1 >= minimum_break))

    case List.last(line_breaks) do
      break_bytes when is_integer(break_bytes) ->
        break_bytes

      nil ->
        Regex.scan(~r/[\s，。；！？、,.!?;:]+/u, prefix, return: :index)
        |> Enum.map(fn [{start, length}] -> start + length end)
        |> Enum.filter(&(&1 >= minimum_break))
        |> List.last()
    end
  end

  # A table never spans a blank line, so it never spans two blocks, and the
  # byte budget keeps split chunks of one oversized block on separate pages.
  # Summing per-segment table counts therefore equals counting the packed page.
  defp pack_segments(segments, max_bytes, max_tables) do
    segments
    |> Enum.map(&Map.put(&1, :tables, count_tables(&1.content)))
    |> Enum.reduce({[], nil}, fn segment, {pages, current} ->
      cond do
        is_nil(current) ->
          {pages, segment}

        byte_size(current.content) + byte_size(segment.content) <= max_bytes and
            current.tables + segment.tables <= max_tables ->
          {pages,
           %{
             source: current.source <> segment.source,
             content: current.content <> segment.content,
             tables: current.tables + segment.tables
           }}

        true ->
          {[current | pages], segment}
      end
    end)
    |> then(fn {pages, current} ->
      pages = if is_nil(current), do: pages, else: [current | pages]
      Enum.reverse(pages)
    end)
  end

  defp fence_open(line) do
    case Regex.run(~r/^\s*(`{3,}|~{3,})[^\n]*\n?$/u, line, capture: :all_but_first) do
      [marker] -> {marker, line}
      _match -> nil
    end
  end

  defp fence_close?(line, marker) do
    Regex.match?(~r/^\s*#{Regex.escape(marker)}+\s*\n?$/u, line)
  end

  defp ensure_trailing_newline(text) do
    if String.ends_with?(text, "\n"), do: text, else: text <> "\n"
  end

  defp non_empty_content(""), do: " "
  defp non_empty_content(content), do: content
end
