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
      :miss -> call_manager(client, :fetch)
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
    {:ok, %{client: client, key: app_token_key(client), fetch: nil, refresh_timer: nil}}
  end

  @impl true
  def handle_call(:fetch, from, state) do
    case lookup(state.key) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :miss ->
        case state.fetch do
          nil -> {:noreply, start_fetch(state, [from])}
          fetch -> {:noreply, %{state | fetch: %{fetch | waiters: [from | fetch.waiters]}}}
        end
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    state = %{state | refresh_timer: nil}
    {:noreply, if(is_nil(state.fetch), do: start_fetch(state, []), else: state)}
  end

  def handle_info({:fetch_done, result}, state), do: {:noreply, finish_fetch(state, result)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{fetch: %{ref: ref}} = state) do
    result = {:error, Error.transport({:token_fetch_crashed, {:exit, reason}})}
    {:noreply, finish_fetch(state, result)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp finish_fetch(state, result) do
    if state.fetch.ref, do: Process.demonitor(state.fetch.ref, [:flush])
    Enum.each(state.fetch.waiters, &GenServer.reply(&1, client_result(result)))
    state = %{state | fetch: nil}

    case result do
      {:ok, _token, expires_at_ms} -> schedule_refresh(state, expires_at_ms)
      _other -> state
    end
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

  defp start_fetch(state, waiters) do
    state = cancel_refresh_timer(state)
    parent = self()
    client = state.client
    key = state.key

    case start_fetch_task(fn -> send(parent, {:fetch_done, safe_fetch(client, key)}) end) do
      {:ok, pid} ->
        %{state | fetch: %{ref: Process.monitor(pid), waiters: waiters}}

      {:error, reason} ->
        result = {:error, Error.transport({:fetch_start_failed, reason})}
        Enum.each(waiters, &GenServer.reply(&1, result))
        state
    end
  end

  defp start_fetch_task(fun) do
    try do
      Task.Supervisor.start_child(DingTalkOpenAPI.EventTaskSupervisor, fun)
    catch
      :exit, reason -> {:error, reason}
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

  defp schedule_refresh(state, expires_at_ms) do
    state = cancel_refresh_timer(state)
    delay = expires_at_ms - System.monotonic_time(:millisecond) - @refresh_lead_ms

    if delay > 0,
      do: %{state | refresh_timer: Process.send_after(self(), :refresh, delay)},
      else: state
  end

  defp cancel_refresh_timer(state) do
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)
    %{state | refresh_timer: nil}
  end

  defp app_token_key(%Client{} = client), do: {:app, Client.cache_namespace(client)}
end
