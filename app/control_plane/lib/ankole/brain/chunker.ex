defmodule Ankole.Brain.Chunker do
  @moduledoc """
  CJK-aware recursive text chunker, ported from the GBrain reference
  implementation: recursive delimiter splitting, greedy merge toward the
  target size, sentence-aware overlap, then hard character and token caps.

  BrainV3 adaptations: audience segmentation happens before this module (each
  input is one single-scope text), the token cap uses the Kernel `o200k_base`
  estimator with the configurable `brain.chunking.max_tokens` budget, and
  oversized single runs split on Unicode grapheme boundaries.
  """

  alias Ankole.Kernel, as: NativeKernel

  # Bump on any change that affects chunk boundaries; the value enters the
  # chunking signature so Self-healing rebuilds pages chunked by old code.
  @chunker_version "brain-chunker-v1"

  @cjk_chars ~r/[\x{4E00}-\x{9FFF}\x{3040}-\x{309F}\x{30A0}-\x{30FF}\x{AC00}-\x{D7AF}]/u
  @cjk_density_threshold 0.30

  # 5-level delimiter hierarchy: paragraphs, lines, sentences, clauses, words.
  @delimiters [
    ["\n\n"],
    ["\n"],
    [". ", "! ", "? ", ".\n", "!\n", "?\n", "。", "！", "？"],
    ["; ", ": ", ", ", "；", "：", "，", "、"],
    []
  ]

  # Head graphemes measured to extrapolate token density before the exact
  # per-slice re-check; the estimator is superlinear on CJK.
  @density_probe_chars 2_000

  @type chunk :: %{text: String.t(), index: non_neg_integer()}

  @doc """
  Returns the chunking signature for one settings map: chunker code version
  plus canonical-encoded runtime parameters, hashed by the Kernel.
  """
  @spec signature(map()) :: String.t()
  def signature(chunking) when is_map(chunking) do
    canonical =
      Enum.join(
        [
          @chunker_version,
          chunking["chunk_size"],
          chunking["chunk_overlap"],
          chunking["max_chars"],
          chunking["max_tokens"]
        ],
        "|"
      )

    NativeKernel.xxh3_128_hex(canonical)
  end

  @doc """
  Chunks one single-scope text with the given settings map.
  """
  @spec chunk_text(String.t(), map()) :: [chunk()]
  def chunk_text(text, chunking) when is_binary(text) and is_map(chunking) do
    chunk_size = chunking["chunk_size"]
    chunk_overlap = chunking["chunk_overlap"]
    max_chars = chunking["max_chars"]
    max_tokens = chunking["max_tokens"]

    if String.trim(text) == "" do
      []
    else
      chunks =
        if count_words(text) <= chunk_size do
          cap_chunk(String.trim(text), max_chars, max_tokens)
        else
          text
          |> recursive_split(0, chunk_size)
          |> greedy_merge(chunk_size)
          |> apply_overlap(chunk_overlap)
          |> Enum.flat_map(&cap_chunk(String.trim(&1), max_chars, max_tokens))
        end

      chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk_text, index} -> %{text: chunk_text, index: index} end)
    end
  end

  @doc """
  CJK-aware word count. At or above 30% CJK character density every
  non-whitespace grapheme counts as one word; below it, whitespace tokens
  count.
  """
  @spec count_words(String.t()) :: non_neg_integer()
  def count_words(""), do: 0

  def count_words(text) when is_binary(text) do
    non_whitespace = String.replace(text, ~r/\s/u, "")
    non_whitespace_count = String.length(non_whitespace)

    if non_whitespace_count == 0 do
      0
    else
      cjk_count = length(Regex.scan(@cjk_chars, non_whitespace))

      if cjk_count / non_whitespace_count >= @cjk_density_threshold do
        non_whitespace_count
      else
        length(Regex.scan(~r/\S+/u, text))
      end
    end
  end

  @doc """
  Estimates embedding tokens for one text through the Kernel o200k_base
  estimator.
  """
  @spec estimate_tokens(String.t()) :: non_neg_integer()
  def estimate_tokens(text), do: NativeKernel.estimate_o200k_base_tokens(text)

  # Recursive split

  defp recursive_split(text, level, target) when level >= length(@delimiters),
    do: split_on_whitespace(text, target)

  defp recursive_split(text, level, target) do
    delimiters = Enum.at(@delimiters, level)

    if delimiters == [] do
      split_on_whitespace(text, target)
    else
      pieces = split_at_delimiters(text, delimiters)

      if length(pieces) <= 1 do
        recursive_split(text, level + 1, target)
      else
        Enum.flat_map(pieces, fn piece ->
          if count_words(piece) > target,
            do: recursive_split(piece, level + 1, target),
            else: [piece]
        end)
      end
    end
  end

  # Splits at delimiter boundaries, keeping each delimiter at the end of the
  # piece before it, so non-overlapping pieces reassemble to the original.
  defp split_at_delimiters(text, delimiters) do
    split_at_delimiters(text, delimiters, [])
  end

  defp split_at_delimiters("", _delimiters, acc), do: Enum.reverse(acc)

  defp split_at_delimiters(remaining, delimiters, acc) do
    earliest =
      delimiters
      |> Enum.map(fn delimiter ->
        case :binary.match(remaining, delimiter) do
          {start, length} -> {start, length}
          :nomatch -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.min_by(fn {start, _length} -> start end, fn -> nil end)

    case earliest do
      nil ->
        pieces = if String.trim(remaining) == "", do: acc, else: [remaining | acc]
        Enum.reverse(pieces)

      {start, length} ->
        piece = binary_part(remaining, 0, start + length)
        rest = binary_part(remaining, start + length, byte_size(remaining) - start - length)
        acc = if String.trim(piece) == "", do: acc, else: [piece | acc]
        split_at_delimiters(rest, delimiters, acc)
    end
  end

  # Whitespace fallback. Whitespace-less input, or a single run longer than
  # the target (a CJK paragraph, a base64 blob, a long URL), slices on
  # grapheme boundaries so the chunker keeps making forward progress.
  defp split_on_whitespace(text, target) do
    words = Regex.scan(~r/\S+\s*/u, text) |> Enum.map(fn [word] -> word end)

    no_useful_whitespace =
      words == [] or (length(words) == 1 and String.length(hd(words)) > target)

    cond do
      no_useful_whitespace and String.trim(text) == "" ->
        []

      no_useful_whitespace ->
        text
        |> slice_graphemes(max(target, 1))
        |> Enum.reject(&(String.trim(&1) == ""))

      true ->
        words
        |> Enum.chunk_every(target)
        |> Enum.map(&Enum.join/1)
        |> Enum.reject(&(String.trim(&1) == ""))
    end
  end

  defp slice_graphemes(text, size) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(size)
    |> Enum.map(&Enum.join/1)
  end

  # Greedy merge and overlap

  defp greedy_merge([], _target), do: []

  defp greedy_merge([first | rest], target) do
    limit = ceil(target * 1.5)

    {chunks, current} =
      Enum.reduce(rest, {[], first}, fn piece, {chunks, current} ->
        combined = current <> piece

        if count_words(combined) <= limit,
          do: {chunks, combined},
          else: {[current | chunks], piece}
      end)

    chunks = if String.trim(current) == "", do: chunks, else: [current | chunks]
    Enum.reverse(chunks)
  end

  defp apply_overlap(chunks, overlap_words) when length(chunks) <= 1 or overlap_words <= 0,
    do: chunks

  defp apply_overlap([first | rest], overlap_words) do
    {overlapped, _previous} =
      Enum.reduce(rest, {[first], first}, fn chunk, {acc, previous} ->
        trailing = extract_trailing_context(previous, overlap_words)
        {[trailing <> chunk | acc], chunk}
      end)

    Enum.reverse(overlapped)
  end

  # Last N words of the previous chunk, preferring a sentence-boundary start.
  defp extract_trailing_context(text, target_words) do
    words = Regex.scan(~r/\S+\s*/u, text) |> Enum.map(fn [word] -> word end)

    if length(words) <= target_words do
      ""
    else
      trailing = words |> Enum.take(-target_words) |> Enum.join()

      case Regex.run(~r/[.!?]\s+/, trailing, return: :index) do
        [{start, _length}] when start < div(byte_size(trailing), 2) ->
          after_sentence =
            trailing
            |> binary_part(start, byte_size(trailing) - start)
            |> String.replace(~r/^[.!?]\s+/, "")

          if String.trim(after_sentence) == "", do: trailing, else: after_sentence

        _no_boundary ->
          trailing
      end
    end
  end

  # Hard caps

  # Sliding-window cap by graphemes AND estimated tokens. The window derives
  # from measured token density when the text exceeds the token budget, and
  # every emitted slice is re-checked exactly, so the cap holds for CJK-dense
  # text that a character cap alone cannot bound.
  defp cap_chunk(text, max_chars, max_tokens, known_est \\ nil)

  defp cap_chunk("", _max_chars, _max_tokens, _known_est), do: []

  defp cap_chunk(text, max_chars, max_tokens, known_est) do
    text_length = String.length(text)
    est = known_est || probe_tokens(text, text_length)

    window =
      if est <= max_tokens do
        max_chars
      else
        max(1, min(max_chars, div(text_length * max_tokens, est)))
      end

    if text_length <= window do
      cond do
        known_est != nil or text_length <= @density_probe_chars ->
          [text]

        true ->
          exact = estimate_tokens(text)

          if exact <= max_tokens,
            do: [text],
            else: cap_chunk(text, max_chars, max_tokens, exact)
      end
    else
      overlap = min(500, div(window, 10))
      stride = max(1, window - overlap)
      graphemes = String.graphemes(text)
      slide_windows(graphemes, text_length, window, stride, max_chars, max_tokens, [])
    end
  end

  defp slide_windows(graphemes, remaining_length, window, stride, max_chars, max_tokens, acc) do
    slice = graphemes |> Enum.take(window) |> Enum.join() |> String.trim()

    acc =
      cond do
        slice == "" ->
          acc

        true ->
          slice_est = estimate_tokens(slice)

          if slice_est > max_tokens do
            Enum.reverse(cap_chunk(slice, max_chars, max_tokens, slice_est)) ++ acc
          else
            [slice | acc]
          end
      end

    if remaining_length <= window do
      Enum.reverse(acc)
    else
      rest = Enum.drop(graphemes, stride)

      slide_windows(
        rest,
        remaining_length - stride,
        window,
        stride,
        max_chars,
        max_tokens,
        acc
      )
    end
  end

  defp probe_tokens(text, text_length) do
    if text_length <= @density_probe_chars do
      estimate_tokens(text)
    else
      head = String.slice(text, 0, @density_probe_chars)
      ceil(estimate_tokens(head) * text_length / @density_probe_chars)
    end
  end
end
