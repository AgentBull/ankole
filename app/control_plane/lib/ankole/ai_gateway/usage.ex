defmodule Ankole.AIGateway.Usage do
  @moduledoc """
  Reads Provider token usage in the Responses usage shape.

  The Rust kernel keeps a count that the Provider did not report as `nil`, so
  `counts/1` can tell it apart from a reported zero. `normalize/1` projects the
  same usage to the public Responses object, whose counts are always integers.

  Counts must be nonnegative integers. Canonical detail fields take priority
  over older Provider names and flat fields, including an explicit zero.
  """

  @input_keys ~w(input_tokens prompt_tokens inputTokens)
  @output_keys ~w(output_tokens completion_tokens outputTokens)

  @doc """
  Adds numeric usage counters recursively, retaining provider-specific fields.

  A counter that only one side reported keeps that side's value, so a missing
  count never replaces or zeroes a reported one.
  """
  def merge(nil, usage), do: usage
  def merge(usage, nil), do: usage

  def merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left, right ->
      cond do
        is_number(left) and is_number(right) -> left + right
        is_map(left) and is_map(right) -> merge(left, right)
        is_nil(right) -> left
        true -> right
      end
    end)
  end

  @doc "Returns the counts of one usage; a count that the Provider did not report is `nil`."
  @spec counts(term()) :: %{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cached_input_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil
        }
  def counts(usage) when is_map(usage) do
    %{
      input_tokens: integer(usage, @input_keys),
      output_tokens: integer(usage, @output_keys),
      cached_input_tokens:
        detail(
          usage,
          ~w(input_tokens_details prompt_tokens_details),
          ~w(cached_tokens cached cachedInputTokens),
          ~w(cached_tokens cachedTokens)
        ),
      reasoning_tokens:
        detail(
          usage,
          ~w(output_tokens_details completion_tokens_details),
          ~w(reasoning_tokens reasoning reasoningTokens),
          ~w(reasoning_tokens reasoningTokens)
        )
    }
  end

  def counts(_usage), do: counts(%{})

  @doc """
  Projects usage to the public Responses usage object.

  A count that the Provider did not report is 0, and a missing or invalid total
  is the sum of input and output.
  """
  @spec normalize(term()) :: map()
  def normalize(usage) do
    counts = counts(usage)
    input = counts.input_tokens || 0
    output = counts.output_tokens || 0

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => integer(usage, ~w(total_tokens totalTokens)) || input + output,
      "input_tokens_details" => %{"cached_tokens" => counts.cached_input_tokens || 0},
      "output_tokens_details" => %{"reasoning_tokens" => counts.reasoning_tokens || 0}
    }
  end

  @spec total_tokens(term()) :: non_neg_integer()
  def total_tokens(usage), do: normalize(usage)["total_tokens"]

  defp detail(usage, detail_keys, keys, flat_keys) do
    Enum.find_value(detail_keys, fn key -> integer(Map.get(usage, key), keys) end) ||
      integer(usage, flat_keys)
  end

  defp integer(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _invalid -> nil
      end
    end)
  end

  defp integer(_map, _keys), do: nil
end
