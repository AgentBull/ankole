defmodule DingTalkOpenAPI.TokenManager do
  @moduledoc """
  Per-app GenServer that serializes app-access-token fetches, caches them in
  shared ETS, and schedules proactive refreshes ahead of expiry.

  DingTalk enterprise-internal apps have a single token type: the app access
  token, obtained from `POST /v1.0/oauth2/accessToken` with `{appKey,
  appSecret}` and valid for `expireIn` seconds (nominally 7200). Both API
  domains share the same token value.

  ## Topology

  One `TokenManager` per credential set (keyed by `Client.cache_namespace/1`),
  registered in `DingTalkOpenAPI.TokenRegistry` and supervised by
  `DingTalkOpenAPI.TokenManager.Supervisor`. Processes start lazily on the first
  token miss. The ETS table (`DingTalkOpenAPI.TokenStore`) is shared across all
  managers — reads are lock-free; misses funnel through this GenServer, which
  coalesces a concurrent burst into a single upstream fetch.
  """

  use GenServer

  alias DingTalkOpenAPI.{Client, Error, TokenStore}

  # Treat a token as expired this long before its nominal expiry so it is never
  # used right as it lapses (clock skew, server-side early expiry, in-flight
  # request latency).
  @expiry_delta_ms :timer.minutes(3)
  # Fire the proactive refresh this far ahead of the (already shortened) expiry.
  @refresh_lead_ms :timer.seconds(30)
  # Caller-side bound on a token fetch. Must exceed Req's receive timeout.
  @call_timeout :timer.seconds(15)

  @token_path "/v1.0/oauth2/accessToken"

  @type key :: {:app, Client.cache_namespace()}

  # Public API

  @doc false
  @spec start_link(Client.t()) :: GenServer.on_start()
  def start_link(%Client{} = client) do
    GenServer.start_link(__MODULE__, client, name: via_tuple(Client.cache_namespace(client)))
  end

  @doc false
  def child_spec(%Client{} = client) do
    %{
      id: {__MODULE__, Client.cache_namespace(client)},
      start: {__MODULE__, :start_link, [client]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Returns an app access token, fetching it through the per-app manager on miss."
  @spec get_app_token(Client.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_app_token(%Client{} = client) do
    key = app_token_key(client)

    case lookup(key) do
      {:ok, token} -> {:ok, token}
      :miss -> call_manager(client, {:fetch, key})
    end
  end

  @doc "Removes the cached app token so the next request fetches a fresh one."
  @spec invalidate(Client.t()) :: :ok
  def invalidate(%Client{} = client) do
    :ets.delete(TokenStore.table(), app_token_key(client))
    :ok
  end

  # GenServer callbacks

  @impl true
  def init(%Client{} = client) do
    {:ok, %{client: client, fetches: %{}, fetch_tasks: %{}, refresh_timers: %{}}}
  end

  @impl true
  def handle_call({:fetch, key}, from, state) do
    case lookup(key) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :miss ->
        # Calls for the same cold key are coalesced onto one task.
        {:noreply, enqueue_waiter(state, key, from)}
    end
  end

  @impl true
  def handle_info({:refresh, key}, state) do
    state = update_in(state.refresh_timers, &Map.delete(&1, key))

    if Map.has_key?(state.fetches, key) do
      {:noreply, state}
    else
      {:noreply, start_fetch(state, key, [])}
    end
  end

  def handle_info({:fetch_done, key, result}, state) do
    state = drop_fetch_task_monitor(state, key)
    {:noreply, finish_fetch(state, key, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.fetch_tasks, ref) do
      {nil, _fetch_tasks} ->
        {:noreply, state}

      {key, fetch_tasks} ->
        result = {:error, Error.transport({:token_fetch_crashed, {:exit, reason}})}
        {:noreply, finish_fetch(%{state | fetch_tasks: fetch_tasks}, key, result)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Internal

  defp finish_fetch(state, key, result) do
    {waiters, fetches} = Map.pop(state.fetches, key, [])
    state = %{state | fetches: fetches}

    Enum.each(waiters, fn {:waiter, from} -> GenServer.reply(from, client_result(result)) end)

    state =
      case result do
        {:ok, _token, expires_at_ms} when is_integer(expires_at_ms) ->
          schedule_refresh(state, key, expires_at_ms)

        _other ->
          state
      end

    state
  end

  defp client_result({:ok, token, _expires_at}), do: {:ok, token}
  defp client_result({:error, _reason} = err), do: err

  defp via_tuple(cache_namespace),
    do: {:via, Registry, {DingTalkOpenAPI.TokenRegistry, cache_namespace}}

  defp call_manager(%Client{} = client, message) do
    pid = ensure_started(client)
    GenServer.call(pid, message, @call_timeout)
  end

  defp ensure_started(%Client{} = client) do
    cache_namespace = Client.cache_namespace(client)

    case Registry.lookup(DingTalkOpenAPI.TokenRegistry, cache_namespace) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               DingTalkOpenAPI.TokenManager.Supervisor,
               {__MODULE__, client}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp lookup(key) do
    case :ets.lookup(TokenStore.table(), key) do
      [{^key, token, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, token}
        else
          :ets.delete(TokenStore.table(), key)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp enqueue_waiter(state, key, from) do
    case Map.fetch(state.fetches, key) do
      {:ok, waiters} ->
        %{state | fetches: Map.put(state.fetches, key, [{:waiter, from} | waiters])}

      :error ->
        start_fetch(state, key, [{:waiter, from}])
    end
  end

  defp start_fetch(state, key, initial_waiters) do
    state = cancel_refresh_timer(state, key)
    fetches = Map.put(state.fetches, key, initial_waiters)

    parent = self()
    client = state.client

    case start_fetch_task(fn ->
           result = safe_fetch(client, key)
           send(parent, {:fetch_done, key, result})
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{state | fetches: fetches, fetch_tasks: Map.put(state.fetch_tasks, ref, key)}

      {:error, reason} ->
        send(parent, {:fetch_done, key, {:error, Error.transport({:fetch_start_failed, reason})}})
        %{state | fetches: fetches}
    end
  end

  defp start_fetch_task(fun) do
    try do
      Task.Supervisor.start_child(DingTalkOpenAPI.EventTaskSupervisor, fun)
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp drop_fetch_task_monitor(state, key) do
    case Enum.find(state.fetch_tasks, fn {_ref, task_key} -> task_key == key end) do
      nil ->
        state

      {ref, ^key} ->
        Process.demonitor(ref, [:flush])
        %{state | fetch_tasks: Map.delete(state.fetch_tasks, ref)}
    end
  end

  defp safe_fetch(%Client{} = client, key) do
    do_fetch(client, key)
  rescue
    exception ->
      {:error, Error.transport({:token_fetch_crashed, exception})}
  catch
    kind, reason ->
      {:error, Error.transport({:token_fetch_crashed, {kind, reason}})}
  end

  defp do_fetch(%Client{} = client, {:app, _ns} = key) do
    body = %{"appKey" => client.client_id, "appSecret" => Client.client_secret(client)}

    case DingTalkOpenAPI.post(client, @token_path, body: body, token: nil) do
      {:ok, %{"accessToken" => token, "expireIn" => expire}}
      when is_binary(token) and is_integer(expire) ->
        cache_and_return(key, token, expire)

      {:ok, other} ->
        {:error, %Error{reason: :unexpected_shape, raw: other}}

      {:error, _reason} = err ->
        err
    end
  end

  defp cache_and_return(key, token, expire_seconds) do
    expires_at =
      System.monotonic_time(:millisecond) + :timer.seconds(expire_seconds) - @expiry_delta_ms

    :ets.insert(TokenStore.table(), {key, token, expires_at})
    {:ok, token, expires_at}
  end

  defp schedule_refresh(state, key, expires_at_ms) do
    state = cancel_refresh_timer(state, key)
    delay = expires_at_ms - System.monotonic_time(:millisecond) - @refresh_lead_ms

    if delay > 0 do
      timer = Process.send_after(self(), {:refresh, key}, delay)
      %{state | refresh_timers: Map.put(state.refresh_timers, key, timer)}
    else
      state
    end
  end

  defp cancel_refresh_timer(state, key) do
    case Map.pop(state.refresh_timers, key) do
      {nil, _rest} ->
        state

      {timer, rest} ->
        _ = Process.cancel_timer(timer)
        %{state | refresh_timers: rest}
    end
  end

  defp app_token_key(%Client{} = client), do: {:app, Client.cache_namespace(client)}
end
