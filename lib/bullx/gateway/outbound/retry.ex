defmodule BullX.Gateway.Outbound.Retry do
  @moduledoc false

  alias BullX.Retry

  @retryable ~w(rate_limit network timeout provider_unavailable)
  @terminal ~w(auth permission not_found payload unsupported contract security_denied)

  @spec policy(map() | nil) :: Retry.t()
  def policy(config) do
    config =
      config
      |> stringify_keys()
      |> Map.merge(%{
        max_attempts: value(config, "max_attempts", 3),
        retryable_kinds: value(config, "retryable_kinds", @retryable),
        terminal_kinds: value(config, "terminal_kinds", @terminal),
        base_backoff_ms: value(config, "base_backoff_ms", 1000),
        max_backoff_ms: value(config, "max_backoff_ms", 30_000)
      })

    Retry.build(config)
  end

  @spec retry?(Retry.t(), map(), non_neg_integer()) :: boolean()
  def retry?(%Retry{} = policy, error, attempts) when is_map(error) do
    case retry_class(policy, error, attempts) do
      :retry -> true
      :terminal -> false
    end
  end

  defp retry_class(
         %Retry{} = policy,
         %{"kind" => kind, "details" => %{"is_transient" => true}},
         attempts
       )
       when is_binary(kind) do
    case attempts < policy.max_attempts do
      true -> :retry
      false -> :terminal
    end
  end

  defp retry_class(%Retry{} = policy, error, attempts),
    do: Retry.classify(policy, error, attempts)

  defp stringify_keys(config) when is_map(config) do
    Map.new(config, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_keys(_config), do: %{}

  defp value(config, key, default) when is_map(config) do
    Map.get(config, key) || Map.get(config, String.to_atom(key)) || default
  end

  defp value(_config, _key, default), do: default
end
