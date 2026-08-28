defmodule Ankole.IdentityProviders.LocalPassword.RetryGuard do
  @moduledoc """
  In-memory attempt limiter for local password sign-in.

  PostgreSQL owns accounts and credentials. This process owns only derived
  runtime state: recent password attempts per account key. A restart clears the
  counters and can let one extra burst of attempts through, but it cannot lose
  an account or a credential, so the state stays in process memory.

  `register_attempt/2` reserves the attempt before the caller runs the hash
  verification, in the same serialized GenServer call that enforces the limit.
  Counting after verification instead would let concurrent requests all pass
  the limit check first and verify without bound. A successful sign-in clears
  the account key, so only failed attempts accumulate.

  An account key locks while it holds `@max_attempts` reserved attempts inside
  `@window_ms`, so at most `@max_attempts` password guesses run per window.
  The lock ends when the oldest counted attempt ages out, or at once when the
  caller reports a newer credential through `:not_before_ms`: guesses against
  a replaced password prove nothing about the new one, and the credential
  row's `updated_at` is durable, so a rescue reset from another OS process
  also unlocks the account.

  Account keys are stored as fixed-size hashes. The process admits at most
  `@max_account_keys` keys. When another new key reaches that full bound, all
  account keys receive the same temporary lock until one admitted key expires.
  This fail-closed saturation keeps both memory and password hash work bounded
  without exposing whether an email address belongs to an account.
  """

  use GenServer

  @max_attempts 5
  @max_account_keys 10_000
  @window_ms :timer.minutes(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Reserves one password attempt for an account key, or reports the lock.

  `:not_before_ms` drops attempts recorded at or before that time, normally
  the moment the current credential was written.
  """
  @spec register_attempt(String.t(), keyword()) :: :ok | {:locked, pos_integer()}
  def register_attempt(account_key, opts \\ []) when is_binary(account_key) and is_list(opts) do
    GenServer.call(
      __MODULE__,
      {:register_attempt, account_key_hash(account_key), Keyword.get(opts, :not_before_ms)}
    )
  end

  @doc """
  Clears the attempt history for an account key after a successful sign-in.
  """
  @spec clear(String.t()) :: :ok
  def clear(account_key) when is_binary(account_key) do
    GenServer.call(__MODULE__, {:clear, account_key_hash(account_key)})
  end

  @doc """
  Drops all attempt history. Test support only.
  """
  @spec reset_for_test() :: :ok
  def reset_for_test do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(:ok) do
    schedule_sweep()
    {:ok, %{attempts_by_account: %{}, saturated_until_ms: nil}}
  end

  @impl true
  def handle_call({:register_attempt, account_key_hash, not_before_ms}, _from, state) do
    now_ms = now_ms()
    state = release_expired_saturation(state, now_ms)

    case state.saturated_until_ms do
      saturated_until_ms when is_integer(saturated_until_ms) ->
        {:reply, locked_until(saturated_until_ms, now_ms), state}

      nil ->
        register_admitted_attempt(state, account_key_hash, not_before_ms, now_ms)
    end
  end

  @impl true
  def handle_call({:clear, account_key}, _from, state) do
    attempts_by_account = Map.delete(state.attempts_by_account, account_key)

    state =
      if map_size(attempts_by_account) < @max_account_keys do
        %{state | attempts_by_account: attempts_by_account, saturated_until_ms: nil}
      else
        %{state | attempts_by_account: attempts_by_account}
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{attempts_by_account: %{}, saturated_until_ms: nil}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()

    attempts_by_account =
      state.attempts_by_account
      |> Enum.flat_map(fn {account_key, attempts} ->
        case prune(attempts, nil) do
          [] -> []
          pruned -> [{account_key, pruned}]
        end
      end)
      |> Map.new()

    saturated_until_ms =
      if map_size(attempts_by_account) < @max_account_keys,
        do: nil,
        else: saturation_end_ms(attempts_by_account)

    {:noreply,
     %{attempts_by_account: attempts_by_account, saturated_until_ms: saturated_until_ms}}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  # Attempt lists store newest first; pruning drops entries older than the
  # window (and older than a replaced credential) and removes the key when
  # nothing recent remains.
  defp register_admitted_attempt(state, account_key, not_before_ms, now_ms) do
    {attempts, attempts_by_account} =
      current_attempts(state.attempts_by_account, account_key, not_before_ms, now_ms)

    cond do
      length(attempts) >= @max_attempts ->
        # Attempt lists store newest first. The lock ends when the oldest of
        # the five counted attempts leaves the window.
        unlock_at_ms = Enum.at(attempts, @max_attempts - 1) + @window_ms

        {:reply, locked_until(unlock_at_ms, now_ms),
         %{state | attempts_by_account: attempts_by_account}}

      attempts == [] and map_size(attempts_by_account) >= @max_account_keys ->
        saturated_until_ms = saturation_end_ms(attempts_by_account)

        {:reply, locked_until(saturated_until_ms, now_ms),
         %{
           state
           | attempts_by_account: attempts_by_account,
             saturated_until_ms: saturated_until_ms
         }}

      true ->
        attempts_by_account = Map.put(attempts_by_account, account_key, [now_ms | attempts])
        {:reply, :ok, %{state | attempts_by_account: attempts_by_account}}
    end
  end

  defp release_expired_saturation(%{saturated_until_ms: nil} = state, _now_ms), do: state

  defp release_expired_saturation(%{saturated_until_ms: until_ms} = state, now_ms)
       when now_ms < until_ms,
       do: state

  defp release_expired_saturation(state, now_ms) do
    attempts_by_account = sweep_attempts(state.attempts_by_account, now_ms)

    saturated_until_ms =
      if map_size(attempts_by_account) < @max_account_keys,
        do: nil,
        else: saturation_end_ms(attempts_by_account)

    %{attempts_by_account: attempts_by_account, saturated_until_ms: saturated_until_ms}
  end

  defp current_attempts(attempts_by_account, account_key, not_before_ms, now_ms) do
    attempts =
      attempts_by_account
      |> Map.get(account_key, [])
      |> prune(not_before_ms, now_ms)

    attempts_by_account =
      case attempts do
        [] -> Map.delete(attempts_by_account, account_key)
        attempts -> Map.put(attempts_by_account, account_key, attempts)
      end

    {attempts, attempts_by_account}
  end

  defp sweep_attempts(attempts_by_account, now_ms) do
    attempts_by_account
    |> Enum.flat_map(fn {account_key, attempts} ->
      case prune(attempts, nil, now_ms) do
        [] -> []
        pruned -> [{account_key, pruned}]
      end
    end)
    |> Map.new()
  end

  defp prune(attempts, not_before_ms, now_ms) do
    cutoff_ms = max(now_ms - @window_ms, not_before_ms || 0)
    Enum.take_while(attempts, &(&1 > cutoff_ms))
  end

  defp prune(attempts, not_before_ms), do: prune(attempts, not_before_ms, now_ms())

  defp saturation_end_ms(attempts_by_account) do
    attempts_by_account
    |> Map.values()
    |> Enum.map(&(hd(&1) + @window_ms))
    |> Enum.min()
  end

  defp locked_until(unlock_at_ms, now_ms) do
    {:locked, max(div(unlock_at_ms - now_ms + 999, 1_000), 1)}
  end

  defp account_key_hash(account_key), do: :crypto.hash(:sha256, account_key)
  defp now_ms, do: System.system_time(:millisecond)
end
