defmodule BullX.AIAgent.Tools.Retry do
  @moduledoc """
  Retries Agent tool calls that return retryable tool errors.

  Tool adapters decide whether an error is retryable. This helper only applies
  bounded exponential backoff, keeping provider-specific failure classification
  out of the Agent loop.
  """

  alias BullX.AIAgent.Tools.Error

  @default_max_attempts 1
  @default_base_delay_ms 100
  @default_max_delay_ms 1_000

  @spec execute((-> {:ok, term()} | {:error, Error.t()}), map() | keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def execute(fun, opts) when is_function(fun, 0) do
    opts = normalize_opts(opts)
    max_attempts = integer_opt(opts, :max_attempts, @default_max_attempts)

    do_execute(fun, opts, 1, max(max_attempts, 1))
  end

  @spec calculate_backoff(non_neg_integer(), map() | keyword()) :: non_neg_integer()
  def calculate_backoff(attempt, opts) when is_integer(attempt) and attempt >= 1 do
    opts = normalize_opts(opts)
    base_delay_ms = integer_opt(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay_ms = integer_opt(opts, :max_delay_ms, @default_max_delay_ms)

    attempt
    |> then(&max(&1 - 1, 0))
    |> then(&:math.pow(2, &1))
    |> round()
    |> Kernel.*(max(base_delay_ms, 0))
    |> min(max(max_delay_ms, 0))
  end

  defp do_execute(fun, opts, attempt, max_attempts) do
    case fun.() do
      {:error, %Error{retryable: true}} when attempt < max_attempts ->
        sleep(opts, calculate_backoff(attempt, opts))
        do_execute(fun, opts, attempt + 1, max_attempts)

      result ->
        result
    end
  end

  defp sleep(opts, delay_ms) when delay_ms <= 0 do
    sleep_fun = Map.get(opts, :sleep_fun)
    if is_function(sleep_fun, 1), do: sleep_fun.(0)
    :ok
  end

  defp sleep(opts, delay_ms) do
    case Map.get(opts, :sleep_fun) do
      sleep_fun when is_function(sleep_fun, 1) -> sleep_fun.(delay_ms)
      _other -> :timer.sleep(delay_ms)
    end
  end

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(_opts), do: %{}

  defp integer_opt(opts, key, default) do
    case Map.get(opts, key, default) do
      value when is_integer(value) -> value
      _value -> default
    end
  end
end
