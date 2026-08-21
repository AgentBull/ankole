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

  A sweep once per window drops aged-out entries for keys that never return,
  so unknown account keys cannot grow the state without bound.
  """

  use GenServer

  @max_attempts 5
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
      {:register_attempt, account_key, Keyword.get(opts, :not_before_ms)}
    )
  end

  @doc """
  Clears the attempt history for an account key after a successful sign-in.
  """
  @spec clear(String.t()) :: :ok
  def clear(account_key) when is_binary(account_key) do
    GenServer.call(__MODULE__, {:clear, account_key})
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
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register_attempt, account_key, not_before_ms}, _from, state) do
    {attempts, state} = current_attempts(state, account_key, not_before_ms)

    case length(attempts) >= @max_attempts do
      true ->
        # The lock ends when enough attempts age out that fewer than
        # @max_attempts remain, which is when the newest counted attempt
        # leaves the window.
        unlock_at_ms = Enum.at(attempts, @max_attempts - 1) + @window_ms
        retry_after_seconds = max(div(unlock_at_ms - now_ms(), 1_000), 1)
        {:reply, {:locked, retry_after_seconds}, state}

      false ->
        {:reply, :ok, Map.put(state, account_key, [now_ms() | attempts])}
    end
  end

  @impl true
  def handle_call({:clear, account_key}, _from, state) do
    {:reply, :ok, Map.delete(state, account_key)}
  end

  @impl true
  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()

    swept =
      state
      |> Enum.flat_map(fn {account_key, attempts} ->
        case prune(attempts, nil) do
          [] -> []
          pruned -> [{account_key, pruned}]
        end
      end)
      |> Map.new()

    {:noreply, swept}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @window_ms)
  end

  # Attempt lists store newest first; pruning drops entries older than the
  # window (and older than a replaced credential) and removes the key when
  # nothing recent remains.
  defp current_attempts(state, account_key, not_before_ms) do
    attempts =
      state
      |> Map.get(account_key, [])
      |> prune(not_before_ms)

    state =
      case attempts do
        [] -> Map.delete(state, account_key)
        attempts -> Map.put(state, account_key, attempts)
      end

    {attempts, state}
  end

  defp prune(attempts, not_before_ms) do
    cutoff_ms = max(now_ms() - @window_ms, not_before_ms || 0)
    Enum.take_while(attempts, &(&1 > cutoff_ms))
  end

  defp now_ms, do: System.system_time(:millisecond)
end
