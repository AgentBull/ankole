defmodule Ankole.IdentityProviders.LocalPassword.RetryGuard do
  @moduledoc """
  Tenant-scoped attempt limits and node-wide password verification permits.

  PostgreSQL owns accounts and credentials. Each tenant has at most 10,000
  fixed-size account hashes, with five attempts per 30-minute window. Success
  clears the account history; a newer credential removes older attempts.
  A restart clears this derived state.

  A permit reserves an attempt and starts a supervised verification together.
  Unknown accounts use the same path. Each tenant can queue two requests for
  at most one second. Tenants receive free permits in round-robin order.
  Busy responses do not consume an attempt. Caller exit does not release a
  running verification's permit.

  The supervisor stops all verification tasks before restarting this guard.
  Thus a restart cannot add new permits while old native calls still run.
  """

  use GenServer

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema
  alias Ankole.Kernel, as: NativeKernel

  @max_attempts 5
  @max_account_keys 10_000
  @window_ms :timer.minutes(30)
  @window_us @window_ms * 1_000
  @wait_ms 1_000
  @max_waiters 2
  @concurrency_key "principals.local_password.max_verifications"

  @spec concurrency_definition() :: AppConfigure.Definition.t()
  def concurrency_definition do
    AppConfigure.define(
      key: @concurrency_key,
      scope: :global,
      encrypted: false,
      schema: Schema.new(&validate_concurrency/1),
      default_value: 2,
      description:
        "Maximum simultaneous local-password verifications on each control-plane node. Restart the control plane after changing this value."
    )
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Verifies a password after obtaining a permit and an account attempt."
  @spec verify_password(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:locked, pos_integer()} | {:busy, pos_integer()} | {:error, term()}
  def verify_password(tenant_id, account_key, password, password_hash, opts \\ []) do
    request = %{
      tenant_id: tenant_id,
      account_key: :crypto.hash(:sha256, account_key),
      password: password,
      password_hash: password_hash,
      not_before_us: Keyword.get(opts, :not_before_us),
      retry_protection?: Keyword.get(opts, :retry_protection?, true),
      clear_on_match?: Keyword.get(opts, :clear_on_match?, true)
    }

    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:verify, request}, :infinity)
  end

  if Mix.env() == :test do
    @doc false
    def reset_for_test do
      GenServer.call(__MODULE__, :reset)
    end
  end

  @impl true
  def init(opts) do
    max_concurrency =
      case Keyword.fetch(opts, :max_concurrency) do
        {:ok, value} ->
          value

        :error ->
          {:ok, value} = AppConfigure.get(concurrency_definition())
          value
      end

    with {:ok, max_concurrency} <- validate_concurrency(max_concurrency) do
      Process.send_after(self(), :sweep, @window_ms)

      {:ok,
       %{
         tenants: %{},
         saturated: %{},
         waiting: %{},
         order: [],
         running: %{},
         max_concurrency: max_concurrency,
         task_supervisor: Keyword.fetch!(opts, :task_supervisor)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:verify, request}, from, state) do
    request = Map.merge(request, %{from: from, owner_ref: Process.monitor(elem(from, 0))})

    if state.order == [] and map_size(state.running) < state.max_concurrency do
      {:noreply, start_verification(state, request)}
    else
      enqueue(state, request)
    end
  end

  if Mix.env() == :test do
    @impl true
    def handle_call(:reset, _from, %{running: running, order: []} = state)
        when map_size(running) == 0 do
      {:reply, :ok, %{state | tenants: %{}, saturated: %{}}}
    end

    @impl true
    def handle_call(:reset, _from, state),
      do: {:reply, {:error, :verification_in_progress}, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.fetch(state.running, ref) do
      {:ok, request} ->
        state =
          if result == true and request.clear_on_match?,
            do: clear_history(state, request.tenant_id, request.account_key),
            else: state

        reply(request, {:ok, result == true})
        {:noreply, %{state | running: Map.put(state.running, ref, %{request | from: nil})}}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        {:noreply, remove_waiter(state, ref)}

      {request, running} ->
        if request.from, do: reply(request, {:error, :password_verification_failed})
        {:noreply, dispatch(%{state | running: running})}
    end
  end

  @impl true
  def handle_info({:wait_expired, ref}, state) do
    {:noreply, remove_waiter(state, ref, {:busy, 1})}
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @window_ms)
    now_us = now_us()

    tenants =
      state.tenants
      |> Enum.flat_map(fn {tenant_id, accounts} ->
        case sweep_accounts(accounts, now_us) do
          accounts when map_size(accounts) == 0 -> []
          accounts -> [{tenant_id, accounts}]
        end
      end)
      |> Map.new()

    saturated =
      Map.filter(state.saturated, fn {tenant_id, _until_us} ->
        map_size(Map.get(tenants, tenant_id, %{})) >= @max_account_keys
      end)

    {:noreply, %{state | tenants: tenants, saturated: saturated}}
  end

  @impl true
  def format_status(status),
    do: Map.merge(status, %{state: :redacted, message: :redacted, log: []})

  defp enqueue(state, request) do
    waiters = Map.get(state.waiting, request.tenant_id, [])

    if length(waiters) >= @max_waiters do
      reply(request, {:busy, 1})
      {:noreply, state}
    else
      request =
        Map.merge(request, %{
          deadline_ms: System.monotonic_time(:millisecond) + @wait_ms,
          timer: Process.send_after(self(), {:wait_expired, request.owner_ref}, @wait_ms)
        })

      order = if waiters == [], do: state.order ++ [request.tenant_id], else: state.order
      waiting = Map.put(state.waiting, request.tenant_id, waiters ++ [request])
      {:noreply, %{state | order: order, waiting: waiting}}
    end
  end

  defp start_verification(state, request) do
    case reserve_attempt(state, request) do
      {:ok, state} ->
        task =
          Task.Supervisor.async_nolink(
            state.task_supervisor,
            fn ->
              # A dirty NIF continues after a forced process exit. Trap the
              # supervisor's shutdown and return before the task can stop.
              Process.flag(:trap_exit, true)
              NativeKernel.argon2id_verify(request.password, request.password_hash)
            end,
            shutdown: :infinity
          )

        request = Map.drop(request, [:password, :password_hash, :timer, :deadline_ms])
        %{state | running: Map.put(state.running, task.ref, request)}

      {locked, state} ->
        reply(request, locked)
        state
    end
  end

  defp dispatch(%{order: []} = state), do: state

  defp dispatch(state) when map_size(state.running) >= state.max_concurrency, do: state

  defp dispatch(state) do
    [tenant_id | rest] = state.order
    [request | remaining] = Map.fetch!(state.waiting, tenant_id)
    Process.cancel_timer(request.timer)

    state =
      case remaining do
        [] ->
          %{state | waiting: Map.delete(state.waiting, tenant_id), order: rest}

        _ ->
          %{
            state
            | waiting: Map.put(state.waiting, tenant_id, remaining),
              order: rest ++ [tenant_id]
          }
      end

    state =
      if System.monotonic_time(:millisecond) >= request.deadline_ms do
        reply(request, {:busy, 1})
        state
      else
        start_verification(state, request)
      end

    dispatch(state)
  end

  defp remove_waiter(state, ref, result \\ nil) do
    waiting =
      state.waiting
      |> Enum.flat_map(fn {tenant_id, requests} ->
        {removed, remaining} = Enum.split_with(requests, &(&1.owner_ref == ref))

        Enum.each(removed, fn request ->
          Process.cancel_timer(request.timer)
          if result, do: reply(request, result)
        end)

        if remaining == [], do: [], else: [{tenant_id, remaining}]
      end)
      |> Map.new()

    %{state | waiting: waiting, order: Enum.filter(state.order, &Map.has_key?(waiting, &1))}
  end

  defp reserve_attempt(state, %{retry_protection?: false}), do: {:ok, state}

  defp reserve_attempt(state, request) do
    now_us = now_us()
    accounts = Map.get(state.tenants, request.tenant_id, %{})

    attempts =
      accounts |> Map.get(request.account_key, []) |> prune(request.not_before_us, now_us)

    accounts = if attempts == [], do: Map.delete(accounts, request.account_key), else: accounts

    state =
      if map_size(accounts) < @max_account_keys,
        do: put_accounts(state, request.tenant_id, accounts),
        else: state

    saturated_until_us = Map.get(state.saturated, request.tenant_id)

    accounts =
      if saturated_until_us && saturated_until_us <= now_us,
        do: sweep_accounts(accounts, now_us),
        else: accounts

    cond do
      length(attempts) >= @max_attempts ->
        {locked_until(List.last(attempts) + @window_us, now_us), state}

      map_size(accounts) >= @max_account_keys ->
        state =
          if saturated_until_us <= now_us do
            state = %{state | saturated: Map.delete(state.saturated, request.tenant_id)}
            put_accounts(state, request.tenant_id, accounts)
          else
            state
          end

        {locked_until(Map.fetch!(state.saturated, request.tenant_id), now_us), state}

      true ->
        accounts = Map.put(accounts, request.account_key, [now_us | attempts])
        {:ok, put_accounts(state, request.tenant_id, accounts)}
    end
  end

  defp clear_history(state, tenant_id, account_key) do
    accounts = state.tenants |> Map.get(tenant_id, %{}) |> Map.delete(account_key)
    put_accounts(state, tenant_id, accounts)
  end

  defp put_accounts(state, tenant_id, accounts) do
    tenants =
      if map_size(accounts) == 0,
        do: Map.delete(state.tenants, tenant_id),
        else: Map.put(state.tenants, tenant_id, accounts)

    saturated =
      if map_size(accounts) >= @max_account_keys do
        Map.put_new_lazy(state.saturated, tenant_id, fn ->
          accounts |> Map.values() |> Enum.map(&(hd(&1) + @window_us)) |> Enum.min()
        end)
      else
        Map.delete(state.saturated, tenant_id)
      end

    %{state | tenants: tenants, saturated: saturated}
  end

  defp reply(request, result) do
    Process.demonitor(request.owner_ref, [:flush])
    GenServer.reply(request.from, result)
  end

  defp sweep_accounts(accounts, now_us) do
    accounts
    |> Enum.flat_map(fn {key, attempts} ->
      case prune(attempts, nil, now_us) do
        [] -> []
        attempts -> [{key, attempts}]
      end
    end)
    |> Map.new()
  end

  defp prune(attempts, not_before_us, now_us) do
    cutoff_us = now_us - @window_us
    Enum.take_while(attempts, &(&1 > cutoff_us and &1 >= (not_before_us || 0)))
  end

  defp locked_until(unlock_at_us, now_us),
    do: {:locked, max(div(unlock_at_us - now_us + 999_999, 1_000_000), 1)}

  defp validate_concurrency(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_concurrency(_value), do: {:error, :expected_positive_integer}
  # Use the same OS clock as Ecto credential timestamps during clock correction.
  defp now_us, do: System.os_time(:microsecond)
end
