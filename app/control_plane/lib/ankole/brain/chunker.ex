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
  @chunker_version "brain-chunker-v3"

  @cjk_chars ~r/[\x{4E00}-\x{9FFF}\x{3040}-\x{309F}\x{30A0}-\x{30FF}\x{AC00}-\x{D7AF}]/u
  @cjk_density_threshold 0.30

  @type chunk :: %{
          text: String.t(),
          index: non_neg_integer(),
          token_count: non_neg_integer()
        }

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
  Chunks one single-scope text with the given settings map and attaches each
  chunk's exact `o200k_base` token count.
  """
  @spec chunk_text(String.t(), map()) :: [chunk()]
  def chunk_text(text, chunking) when is_binary(text) and is_map(chunking) do
    case NativeKernel.brain_chunk_text_with_tokens(
           text,
           chunking["chunk_size"],
           chunking["chunk_overlap"],
           chunking["max_chars"],
           chunking["max_tokens"]
         ) do
      chunks when is_list(chunks) ->
        chunks
        |> Enum.with_index()
        |> Enum.map(fn {{chunk_text, token_count}, index} ->
          %{text: chunk_text, index: index, token_count: token_count}
        end)

      {:error, reason} ->
        raise ArgumentError, "invalid chunking input: #{reason}"
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
end
