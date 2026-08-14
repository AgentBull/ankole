defmodule Ankole.AIGateway.ToolSearch.Index do
  @moduledoc """
  BM25 ranking over one request-declared tool catalog.

  The corpus is one request's deferred tools, so the index is rebuilt per
  search call instead of cached. Tokenization must serve mixed Chinese and
  English tool metadata: Latin runs become lowercase word tokens split on
  underscores, and Han runs become character bigrams.
  """

  @bm25_k1 1.2
  @bm25_b 0.75

  @doc """
  Returns up to `limit` catalog tools ranked by BM25 score for `query`.

  Tools with zero overlap are excluded; an empty or unmatched query returns an
  empty list rather than arbitrary tools.
  """
  @spec search([map()], String.t(), pos_integer()) :: [map()]
  def search(catalog, query, limit) when is_list(catalog) and is_binary(query) do
    query_tokens = tokenize(query)

    if query_tokens == [] or catalog == [] do
      []
    else
      documents = Enum.map(catalog, &{&1, tokenize(document_text(&1))})
      average_length = average_document_length(documents)
      document_frequency = document_frequency(documents)
      total = length(documents)

      documents
      |> Enum.map(fn {tool, tokens} ->
        {tool, score(query_tokens, tokens, document_frequency, total, average_length)}
      end)
      |> Enum.filter(fn {_tool, score} -> score > 0.0 end)
      |> Enum.sort_by(fn {_tool, score} -> -score end)
      |> Enum.take(limit)
      |> Enum.map(fn {tool, _score} -> tool end)
    end
  end

  @doc false
  @spec tokenize(String.t()) :: [String.t()]
  def tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> split_runs()
    |> Enum.flat_map(&run_tokens/1)
  end

  defp document_text(tool) do
    [
      Map.get(tool, "__ankole_search_text"),
      Map.get(tool, "name"),
      Map.get(tool, "namespace"),
      Map.get(tool, "namespace_description"),
      Map.get(tool, "description"),
      parameter_names(tool)
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  defp parameter_names(%{"parameters" => %{"properties" => %{} = properties}}),
    do: properties |> Map.keys() |> Enum.join(" ")

  defp parameter_names(_tool), do: nil

  defp average_document_length(documents) do
    lengths = Enum.map(documents, fn {_tool, tokens} -> length(tokens) end)

    case lengths do
      [] -> 1.0
      lengths -> max(Enum.sum(lengths) / length(lengths), 1.0)
    end
  end

  defp document_frequency(documents) do
    Enum.reduce(documents, %{}, fn {_tool, tokens}, acc ->
      tokens
      |> Enum.uniq()
      |> Enum.reduce(acc, fn token, acc -> Map.update(acc, token, 1, &(&1 + 1)) end)
    end)
  end

  defp score(query_tokens, document_tokens, document_frequency, total, average_length) do
    frequencies = Enum.frequencies(document_tokens)
    document_length = max(length(document_tokens), 1)

    query_tokens
    |> Enum.uniq()
    |> Enum.reduce(0.0, fn token, acc ->
      case Map.get(frequencies, token, 0) do
        0 ->
          acc

        frequency ->
          documents_with_token = Map.get(document_frequency, token, 0)

          idf =
            :math.log(1.0 + (total - documents_with_token + 0.5) / (documents_with_token + 0.5))

          normalized =
            frequency * (@bm25_k1 + 1) /
              (frequency +
                 @bm25_k1 * (1 - @bm25_b + @bm25_b * document_length / average_length))

          acc + idf * normalized
      end
    end)
  end

  # Splits text into homogeneous runs: Latin word characters, Han characters,
  # or discarded separators.
  defp split_runs(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_while(
      nil,
      fn grapheme, current ->
        kind = grapheme_kind(grapheme)

        case {current, kind} do
          {nil, :separator} -> {:cont, nil}
          {nil, kind} -> {:cont, {kind, [grapheme]}}
          {{kind, graphemes}, kind} -> {:cont, {kind, [grapheme | graphemes]}}
          {run, :separator} -> {:cont, run, nil}
          {run, kind} -> {:cont, run, {kind, [grapheme]}}
        end
      end,
      fn
        nil -> {:cont, nil}
        run -> {:cont, run, nil}
      end
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {kind, graphemes} -> {kind, graphemes |> Enum.reverse() |> Enum.join()} end)
  end

  defp run_tokens({:latin, run}), do: [run]

  defp run_tokens({:han, run}) do
    graphemes = String.graphemes(run)

    case graphemes do
      [single] -> [single]
      graphemes -> graphemes |> Enum.chunk_every(2, 1, :discard) |> Enum.map(&Enum.join/1)
    end
  end

  defp grapheme_kind(grapheme) do
    case grapheme do
      <<code::utf8>> when code in ?a..?z or code in ?0..?9 -> :latin
      _grapheme -> if han?(grapheme), do: :han, else: :separator
    end
  end

  defp han?(<<code::utf8>>) do
    code in 0x4E00..0x9FFF or code in 0x3400..0x4DBF or code in 0xF900..0xFAFF
  end

  defp han?(_grapheme), do: false
end
