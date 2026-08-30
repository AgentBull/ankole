defmodule Ankole.Brain.Markdoc do
  @moduledoc """
  Canonical Brain body syntax over CommonMark block structure.

  The stored body is the content after the rendered Frontmatter. An
  `{% audience scope="..." %}` block attaches one scope to the content it
  wraps; text outside every block uses `world`. The native kernel identifies
  code structure and wikilinks before this module applies Brain scope rules.
  """

  @type segment :: %{scope: String.t(), text: String.t()}

  @doc """
  Returns the native syntax diagnostic for an invalid body.

  This function is for editor feedback. Domain writes still use
  `segments/1` and keep their existing atom error contract.
  """
  @spec diagnostic(String.t()) :: nil | %{code: String.t(), line: pos_integer()}
  def diagnostic(body) when is_binary(body) do
    case Ankole.Kernel.brain_markdoc_analyze(body) do
      %{"error" => %{"code" => code, "line" => line}}
      when is_binary(code) and is_integer(line) and line > 0 ->
        %{code: code, line: line}

      _analysis ->
        nil
    end
  end

  @doc """
  Splits a body into ordered segments, each carrying one audience scope.

  Unwrapped text carries `world`. Returns an error for a nested, unclosed,
  or unopened `audience` tag, and for a scope value that does not parse.
  """
  @spec segments(String.t()) :: {:ok, [segment()]} | {:error, term()}
  def segments(body) when is_binary(body) do
    with {:ok, segments, _wikilinks} <- analyze(body) do
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
    with {:ok, raw_segments, _wikilinks} <- analyze(body) do
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
    case analyze(body) do
      {:ok, _segments, wikilinks} -> wikilinks
      {:error, _reason} -> []
    end
  end

  defp analyze(body) do
    case Ankole.Kernel.brain_markdoc_analyze(body) do
      %{"segments" => segments, "wikilinks" => wikilinks} ->
        with {:ok, segments} <- decode_segments(segments) do
          {:ok, segments, wikilinks}
        end

      %{"error" => %{"code" => code}} ->
        {:error, error_code(code)}

      _other ->
        {:error, :invalid_brain_markdoc_analysis}
    end
  end

  defp decode_segments(segments) when is_list(segments) do
    Enum.reduce_while(segments, {:ok, []}, fn
      %{"scope" => scope, "text" => text}, {:ok, decoded}
      when is_binary(scope) and is_binary(text) ->
        case Ankole.Brain.Scope.parse(scope) do
          {:ok, _parsed} -> {:cont, {:ok, [%{scope: scope, text: text} | decoded]}}
          {:error, _reason} -> {:halt, {:error, {:invalid_audience_scope, scope}}}
        end

      _segment, _decoded ->
        {:halt, {:error, :invalid_brain_markdoc_analysis}}
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_segments(_segments), do: {:error, :invalid_brain_markdoc_analysis}

  defp error_code("nested_audience_tag"), do: :nested_audience_tag
  defp error_code("unopened_audience_tag"), do: :unopened_audience_tag
  defp error_code("unclosed_audience_tag"), do: :unclosed_audience_tag
  defp error_code("misplaced_audience_tag"), do: :misplaced_audience_tag
  defp error_code(_code), do: :invalid_brain_markdoc_analysis
end
