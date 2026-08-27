defmodule Ankole.Brain.Markdoc do
  @moduledoc """
  Markdoc `audience` tag handling for Brain object bodies.

  The stored body is the content after the rendered Frontmatter. An
  `{% audience scope="..." %}` tag attaches one scope to the content it
  wraps; text outside every tag uses `world`. Tags cannot nest: one segment
  carries exactly one scope, which is what lets each chunk row carry exactly
  one `audience_scope`.
  """

  @open_tag ~r/\{%\s*audience\s+scope="([^"]*)"\s*%\}/
  @close_tag ~r/\{%\s*\/audience\s*%\}/
  @wikilink ~r/\[\[([^\[\]\n]+)\]\]/

  @type segment :: %{scope: String.t(), text: String.t()}

  @doc """
  Splits a body into ordered segments, each carrying one audience scope.

  Unwrapped text carries `world`. Returns an error for a nested, unclosed,
  or unopened `audience` tag, and for a scope value that does not parse.
  """
  @spec segments(String.t()) :: {:ok, [segment()]} | {:error, term()}
  def segments(body) when is_binary(body) do
    tokens = tokenize(body)

    with {:ok, segments} <- build_segments(tokens, body) do
      {:ok, Enum.reject(segments, &(String.trim(&1.text) == ""))}
    end
  end

  @doc """
  Returns the distinct scopes used by `audience` tags in a body.
  """
  @spec scopes(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def scopes(body) do
    with {:ok, segments} <- segments(body) do
      {:ok, segments |> Enum.map(& &1.scope) |> Enum.uniq()}
    end
  end

  @doc """
  Wraps a whole body in one `audience` tag.

  A generated document inherits the scope of the evidence it came from, so
  every writer that derives a body from scoped rows sends it through here
  before the write contract. A `world` body needs no tag, because unwrapped
  text is already `world`.
  """
  @spec wrap(String.t(), String.t()) :: String.t()
  def wrap(body, "world") when is_binary(body), do: body

  def wrap(body, scope) when is_binary(body) and is_binary(scope),
    do: ~s({% audience scope="#{scope}" %}\n) <> body <> "\n{% /audience %}"

  @doc """
  Removes the segments whose scope fails `keep?` and renders the remaining
  body in original order. Kept audience blocks keep their tags, so a later
  write of the pruned text would preserve the same scopes.
  """
  @spec prune(String.t(), (String.t() -> boolean())) :: {:ok, String.t()} | {:error, term()}
  def prune(body, keep?) when is_binary(body) and is_function(keep?, 1) do
    tokens = tokenize(body)

    with {:ok, raw_segments} <- build_segments(tokens, body) do
      pruned =
        raw_segments
        |> Enum.filter(fn segment -> keep?.(segment.scope) end)
        |> Enum.map_join("", fn
          %{scope: "world", text: text} ->
            text

          %{scope: scope, text: text} ->
            ~s({% audience scope="#{scope}" %}) <> text <> "{% /audience %}"
        end)

      {:ok, pruned}
    end
  end

  @doc """
  Extracts `[[slug]]` wikilink targets in document order, deduplicated.
  """
  @spec wikilinks(String.t()) :: [String.t()]
  def wikilinks(body) when is_binary(body) do
    @wikilink
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [target] -> String.trim(target) end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp tokenize(body) do
    opens =
      @open_tag
      |> Regex.scan(body, return: :index)
      |> Enum.map(fn [{start, length}, {scope_start, scope_length}] ->
        scope = binary_part(body, scope_start, scope_length)
        {start, length, {:open, scope}}
      end)

    closes =
      @close_tag
      |> Regex.scan(body, return: :index)
      |> Enum.map(fn [{start, length}] -> {start, length, :close} end)

    Enum.sort_by(opens ++ closes, fn {start, _length, _kind} -> start end)
  end

  defp build_segments(tokens, body) do
    initial = %{segments: [], cursor: 0, open: nil}

    tokens
    |> Enum.reduce_while({:ok, initial}, fn {start, length, kind}, {:ok, state} ->
      text_before = binary_part(body, state.cursor, start - state.cursor)

      case {kind, state.open} do
        {{:open, scope}, nil} ->
          case Ankole.Brain.Scope.parse(scope) do
            {:ok, _parsed} ->
              segments = [%{scope: "world", text: text_before} | state.segments]
              {:cont, {:ok, %{segments: segments, cursor: start + length, open: scope}}}

            {:error, _reason} ->
              {:halt, {:error, {:invalid_audience_scope, scope}}}
          end

        {{:open, _scope}, _open} ->
          {:halt, {:error, :nested_audience_tag}}

        {:close, nil} ->
          {:halt, {:error, :unopened_audience_tag}}

        {:close, open_scope} ->
          segments = [%{scope: open_scope, text: text_before} | state.segments]
          {:cont, {:ok, %{segments: segments, cursor: start + length, open: nil}}}
      end
    end)
    |> case do
      {:ok, %{open: open}} when not is_nil(open) ->
        {:error, :unclosed_audience_tag}

      {:ok, state} ->
        tail = binary_part(body, state.cursor, byte_size(body) - state.cursor)
        {:ok, Enum.reverse([%{scope: "world", text: tail} | state.segments])}

      {:error, _reason} = error ->
        error
    end
  end
end
