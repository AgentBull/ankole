defmodule Ankole.AIGateway.Usage do
  @moduledoc """
  Normalizes stored and Provider token usage to the Responses usage shape.

  Counts must be nonnegative integers. Canonical detail fields take priority
  over older Provider names and flat fields, including an explicit zero.
  A missing or invalid total uses the sum of input and output counts.
  """

  @spec normalize(term()) :: map()
  def normalize(usage) when is_map(usage) do
    input = integer(usage, ~w(input_tokens prompt_tokens inputTokens))
    output = integer(usage, ~w(output_tokens completion_tokens outputTokens))
    total = integer(usage, ~w(total_tokens totalTokens), input + output)

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => total,
      "input_tokens_details" => %{
        "cached_tokens" =>
          detail(
            usage,
            ~w(input_tokens_details prompt_tokens_details),
            ~w(cached_tokens cached cachedInputTokens),
            ~w(cached_tokens cachedTokens)
          )
      },
      "output_tokens_details" => %{
        "reasoning_tokens" =>
          detail(
            usage,
            ~w(output_tokens_details completion_tokens_details),
            ~w(reasoning_tokens reasoning reasoningTokens),
            ~w(reasoning_tokens reasoningTokens)
          )
      }
    }
  end

  def normalize(_usage), do: normalize(%{})

  @spec total_tokens(term()) :: non_neg_integer()
  def total_tokens(usage), do: normalize(usage)["total_tokens"]

  defp detail(usage, detail_keys, keys, flat_keys) do
    Enum.find_value(detail_keys, fn key -> integer(Map.get(usage, key), keys, nil) end) ||
      integer(usage, flat_keys)
  end

  defp integer(map, keys, default \\ 0)

  defp integer(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _invalid -> nil
      end
    end)
  end

  defp integer(_map, _keys, default), do: default
end
