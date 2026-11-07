defmodule Ankole.Pod.Pages.Search.Snippets do
  @moduledoc """
  Match-field classification and highlighted snippet segmentation for winning
  `Ankole.Pod.Pages.Search` results.
  """

  @record_sep <<0x1E>>
  @unit_sep <<0x1F>>

  @doc "Classifies which projection fields (`:title`, `:meta`, `:body`) matched."
  @spec detect_match_fields(map(), [String.t()], boolean()) :: [:title | :meta | :body]
  def detect_match_fields(_cand, _lower_terms, true), do: [:title]

  def detect_match_fields(cand, lower_terms, false) do
    title_down = String.downcase(cand.eff_title || "")
    meta_down = String.downcase(cand.meta_text || "")
    body_down = String.downcase(cand.body_text || "")

    title_hit? =
      snippet_has_hit?(cand[:title_snippet]) or
        Enum.any?(lower_terms, &String.contains?(title_down, &1))

    meta_hit? =
      snippet_has_hit?(cand[:meta_snippet]) or
        (meta_down != "" and Enum.any?(lower_terms, &String.contains?(meta_down, &1)))

    body_hit? =
      snippet_has_hit?(cand[:body_snippet]) or
        (body_down != "" and Enum.any?(lower_terms, &String.contains?(body_down, &1)))

    fields =
      []
      |> then(&if(title_hit?, do: [:title | &1], else: &1))
      |> then(&if(meta_hit?, do: [:meta | &1], else: &1))
      |> then(&if(body_hit?, do: [:body | &1], else: &1))
      |> Enum.reverse()

    if fields == [], do: [:body], else: fields
  end

  @doc "Builds a structured snippet segment list for a winning search candidate."
  @spec build_snippet(map(), [:title | :meta | :body], [String.t()], boolean()) ::
          %{segments: [%{text: String.t(), hit: boolean()}]} | nil
  def build_snippet(cand, _match_fields, _terms, true), do: fallback_excerpt_snippet(cand)

  def build_snippet(cand, match_fields, terms, false) do
    body = cand.body_text || ""
    meta = cand.meta_text || ""

    cond do
      snippet_has_hit?(cand[:body_snippet]) ->
        wrap_segments(parse_pdb_snippet(cand.body_snippet, body))

      :body in match_fields and body != "" ->
        wrap_segments(window_highlight_segments(body, terms))

      snippet_has_hit?(cand[:meta_snippet]) ->
        wrap_segments(parse_pdb_snippet(cand.meta_snippet, meta))

      :meta in match_fields and meta != "" ->
        wrap_segments(window_highlight_segments(meta, terms))

      true ->
        fallback_excerpt_snippet(cand)
    end
  end

  @doc false
  @spec parse_pdb_snippet(String.t(), String.t()) :: [%{text: String.t(), hit: boolean()}]
  def parse_pdb_snippet(raw_snippet, full_body) when is_binary(raw_snippet) do
    segments =
      raw_snippet
      |> String.split(@record_sep)
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {chunk, 0} ->
          [{collapse_ws(chunk), false}]

        {chunk, _idx} ->
          case String.split(chunk, @unit_sep, parts: 2) do
            [hit_part, rest_part] ->
              [{collapse_ws(hit_part), true}, {collapse_ws(rest_part), false}]

            [only_part] ->
              [{collapse_ws(only_part), false}]
          end
      end)
      |> Enum.reject(fn {txt, _hit} -> txt == "" end)
      |> merge_adjacent_segments([])

    plain_joined = Enum.map_join(segments, "", & &1.text)
    clean_full = full_body |> collapse_ws() |> String.trim()
    trimmed_joined = String.trim(plain_joined)

    segments
    |> maybe_prepend_ellipsis(
      clean_full != "" and not String.starts_with?(clean_full, trimmed_joined)
    )
    |> maybe_append_ellipsis(
      clean_full != "" and not String.ends_with?(clean_full, trimmed_joined)
    )
  end

  @doc false
  @spec window_highlight_segments(String.t(), [String.t()]) :: [
          %{text: String.t(), hit: boolean()}
        ]
  def window_highlight_segments(source_text, terms) when is_binary(source_text) do
    collapsed = source_text |> collapse_ws() |> String.trim()

    if collapsed == "" do
      []
    else
      graphemes = String.graphemes(collapsed)
      total = length(graphemes)
      lower_collapsed = String.downcase(collapsed)

      sorted_terms =
        terms
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq_by(&String.downcase/1)
        |> Enum.sort_by(&(-String.length(&1)))

      first_char_idx =
        sorted_terms
        |> Enum.flat_map(fn term ->
          case :binary.match(lower_collapsed, String.downcase(term)) do
            {byte_pos, _len} ->
              prefix = binary_part(lower_collapsed, 0, byte_pos)
              [String.length(prefix)]

            :nomatch ->
              []
          end
        end)
        |> Enum.min(fn -> 0 end)

      win_start = max(first_char_idx - 50, 0)
      win_len = 180
      window_str = graphemes |> Enum.slice(win_start, win_len) |> Enum.join()
      escaped = Enum.map_join(sorted_terms, "|", &Regex.escape/1)

      segments =
        if escaped == "" do
          [%{text: window_str, hit: false}]
        else
          regex = Regex.compile!("(#{escaped})", "iu")

          regex
          |> Regex.split(window_str, include_captures: true)
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(fn part -> {part, Regex.match?(regex, part)} end)
          |> merge_adjacent_segments([])
        end

      segments
      |> maybe_prepend_ellipsis(win_start > 0)
      |> maybe_append_ellipsis(win_start + win_len < total)
    end
  end

  defp snippet_has_hit?(raw), do: is_binary(raw) and String.contains?(raw, @record_sep)

  defp wrap_segments([]), do: nil
  defp wrap_segments(segments), do: %{segments: segments}

  defp fallback_excerpt_snippet(cand) do
    source =
      cond do
        (cand.body_text || "") != "" -> cand.body_text
        (cand.meta_text || "") != "" -> cand.meta_text
        true -> ""
      end

    case static_excerpt(source, 180) do
      "" -> nil
      preview -> %{segments: [%{text: preview, hit: false}]}
    end
  end

  defp static_excerpt(text, max_graphemes) do
    collapsed = text |> collapse_ws() |> String.trim()

    if String.length(collapsed) <= max_graphemes do
      collapsed
    else
      String.slice(collapsed, 0, max_graphemes) <> "…"
    end
  end

  defp collapse_ws(text) when is_binary(text) do
    String.replace(text, ~r/[\r\n\t ]+/u, " ")
  end

  defp merge_adjacent_segments([], acc), do: Enum.reverse(acc)

  defp merge_adjacent_segments([{text, hit} | rest], [%{text: prev_text, hit: hit} | tail]) do
    merged_text =
      if hit and prev_text != "" and text != "" and
           not String.ends_with?(prev_text, " ") and not String.starts_with?(text, " ") and
           ascii_word_boundary?(prev_text, text) do
        prev_text <> " " <> text
      else
        prev_text <> text
      end

    merge_adjacent_segments(rest, [%{text: merged_text, hit: hit} | tail])
  end

  defp merge_adjacent_segments([{text, hit} | rest], acc) do
    merge_adjacent_segments(rest, [%{text: text, hit: hit} | acc])
  end

  defp ascii_word_boundary?(left, right) do
    Regex.match?(~r/[A-Za-z0-9]\z/, left) and Regex.match?(~r/\A[A-Za-z0-9]/, right)
  end

  defp maybe_prepend_ellipsis([], _prepend?), do: []
  defp maybe_prepend_ellipsis(segments, false), do: segments

  defp maybe_prepend_ellipsis([%{hit: false, text: text} = first | rest], true) do
    [%{first | text: "…" <> String.trim_leading(text)} | rest]
  end

  defp maybe_prepend_ellipsis(segments, true), do: [%{text: "…", hit: false} | segments]

  defp maybe_append_ellipsis([], _append?), do: []
  defp maybe_append_ellipsis(segments, false), do: segments

  defp maybe_append_ellipsis(segments, true) do
    case List.last(segments) do
      %{hit: false, text: text} = last ->
        List.replace_at(segments, length(segments) - 1, %{
          last
          | text: String.trim_trailing(text) <> "…"
        })

      _ ->
        segments ++ [%{text: "…", hit: false}]
    end
  end
end
