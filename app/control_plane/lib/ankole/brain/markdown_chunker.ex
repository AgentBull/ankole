defmodule Ankole.Brain.MarkdownChunker do
  @moduledoc false

  alias Ankole.Kernel, as: NativeKernel

  @spec split(String.t(), pos_integer()) :: {:ok, [String.t()]} | {:error, term()}
  def split(markdown, max_tokens)
      when is_binary(markdown) and is_integer(max_tokens) and max_tokens > 0 do
    markdown = markdown |> String.replace("\r\n", "\n") |> String.trim()

    if markdown == "" do
      {:error, :empty_source_document}
    else
      markdown
      |> String.split("\n")
      |> Enum.flat_map(&split_line(&1, max_tokens))
      |> pack_lines(max_tokens)
      |> then(&{:ok, &1})
    end
  end

  def split(_markdown, _max_tokens), do: {:error, :invalid_source_chunk_limit}

  defp pack_lines(lines, max_tokens) do
    {chunks, current} =
      Enum.reduce(lines, {[], []}, fn line, {chunks, current} ->
        heading? = Regex.match?(~r/^\#{1,6}\s+\S/u, line)
        candidate = Enum.join(current ++ [line], "\n")

        cond do
          current != [] and heading? ->
            {[Enum.join(current, "\n") | chunks], [line]}

          current != [] and tokens(candidate) > max_tokens ->
            {[Enum.join(current, "\n") | chunks], [line]}

          true ->
            {chunks, current ++ [line]}
        end
      end)

    chunks = if current == [], do: chunks, else: [Enum.join(current, "\n") | chunks]

    chunks
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_line(line, max_tokens) do
    if tokens(line) <= max_tokens do
      [line]
    else
      do_split_graphemes(String.graphemes(line), max_tokens, [])
    end
  end

  defp do_split_graphemes([], _max_tokens, chunks), do: Enum.reverse(chunks)

  defp do_split_graphemes(graphemes, max_tokens, chunks) do
    count = largest_prefix(graphemes, max_tokens)
    {head, tail} = Enum.split(graphemes, max(count, 1))
    do_split_graphemes(tail, max_tokens, [Enum.join(head) | chunks])
  end

  defp largest_prefix(graphemes, max_tokens) do
    1..length(graphemes)
    |> Enum.reduce_while({0, length(graphemes), 1}, fn _, {low, high, best} ->
      if low > high do
        {:halt, {low, high, best}}
      else
        middle = div(low + high, 2)
        candidate = graphemes |> Enum.take(middle) |> Enum.join()

        if tokens(candidate) <= max_tokens do
          {:cont, {middle + 1, high, middle}}
        else
          {:cont, {low, middle - 1, best}}
        end
      end
    end)
    |> elem(2)
  end

  defp tokens(text), do: NativeKernel.estimate_o200k_base_tokens(text)
end
