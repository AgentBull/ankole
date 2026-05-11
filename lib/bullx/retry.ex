defmodule BullX.Retry do
  @moduledoc """
  Retry classification and backoff calculation.

  Originally written for the egress Gateway runtime (RFC 0003 §5.3.2), this
  module is now the shared retry policy across the codebase: anywhere a caller
  has an error map (`%{"kind" => _, "details" => _}`) and an attempt counter,
  these functions decide whether to retry and how long to wait.

  Two surface-level shapes are supported:

    * the egress map shape — `%{"kind" => kind, "details" => %{"retry_after_ms" => ms}}`,
      where `kind` selects retryable vs terminal; and
    * a minimal shape — `%{"kind" => "network"}` — used by callers that only
      need exponential backoff without rich error classification (e.g. long
      polling).
  """

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          base_backoff_ms: pos_integer(),
          max_backoff_ms: pos_integer(),
          retryable_kinds: MapSet.t(String.t()),
          terminal_kinds: MapSet.t(String.t())
        }

  @default_retryable ~w(network rate_limit exception unknown)
  @default_terminal ~w(auth payload unsupported contract stream_lost stream_cancelled adapter_restarted)

  defstruct max_attempts: 5,
            base_backoff_ms: 1000,
            max_backoff_ms: 30_000,
            retryable_kinds: MapSet.new(@default_retryable),
            terminal_kinds: MapSet.new(@default_terminal)

  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Build a policy from a map or keyword list. Unknown keys are ignored, so
  adapter configs may pass extra keys without breaking.
  """
  @spec build(map() | keyword() | nil) :: t()
  def build(nil), do: default()

  def build(config) when is_list(config), do: build(Map.new(config))

  def build(config) when is_map(config) do
    default_policy = default()

    %__MODULE__{
      max_attempts: pos_integer(config, :max_attempts, default_policy.max_attempts),
      base_backoff_ms: pos_integer(config, :base_backoff_ms, default_policy.base_backoff_ms),
      max_backoff_ms: pos_integer(config, :max_backoff_ms, default_policy.max_backoff_ms),
      retryable_kinds: kind_set(config, :retryable_kinds, default_policy.retryable_kinds),
      terminal_kinds: kind_set(config, :terminal_kinds, default_policy.terminal_kinds)
    }
  end

  @doc """
  Classify an error map + current attempt count.

  Returns `:retry` when the kind is retryable and the next attempt is within
  `max_attempts`, `:terminal` otherwise.
  """
  @spec classify(t(), map(), non_neg_integer()) :: :retry | :terminal
  def classify(%__MODULE__{} = policy, error_map, attempts_so_far)
      when is_map(error_map) and is_integer(attempts_so_far) do
    kind = to_string(error_map["kind"] || "unknown")

    cond do
      MapSet.member?(policy.terminal_kinds, kind) -> :terminal
      not MapSet.member?(policy.retryable_kinds, kind) -> :terminal
      attempts_so_far >= policy.max_attempts -> :terminal
      true -> :retry
    end
  end

  @doc """
  Compute the backoff for the next attempt.

  `error.details["retry_after_ms"]` is preferred over the exponential default,
  capped at `max_backoff_ms`.
  """
  @spec backoff_ms(t(), map(), non_neg_integer()) :: non_neg_integer()
  def backoff_ms(%__MODULE__{} = policy, error_map, attempts_so_far)
      when is_map(error_map) and is_integer(attempts_so_far) do
    case error_map["details"] do
      %{"retry_after_ms" => retry_after} when is_integer(retry_after) and retry_after >= 0 ->
        min(retry_after, policy.max_backoff_ms)

      _ ->
        exponential_ms(policy, attempts_so_far)
    end
  end

  defp exponential_ms(policy, attempts_so_far) do
    shift = max(attempts_so_far - 1, 0)
    exponential = policy.base_backoff_ms * Integer.pow(2, shift)
    min(exponential, policy.max_backoff_ms)
  end

  defp pos_integer(config, key, default) do
    case Map.get(config, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp kind_set(config, key, default_set) do
    case Map.get(config, key) do
      list when is_list(list) -> MapSet.new(Enum.map(list, &to_string/1))
      _ -> default_set
    end
  end
end
