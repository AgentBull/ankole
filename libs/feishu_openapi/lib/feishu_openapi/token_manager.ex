defmodule FeishuOpenAPI.TokenManager do
  @moduledoc """
  Per-app GenServer that serializes token fetches, caches results in ETS,
  and schedules proactive refreshes ahead of expiry.

  ## Topology

  One `TokenManager` process per `app_id`, registered in
  `FeishuOpenAPI.TokenRegistry` and supervised by
  `FeishuOpenAPI.TokenManager.Supervisor`. Processes start lazily on the first
  token-miss for a given client. The ETS table (`:feishu_openapi_tokens`) is
  owned by `FeishuOpenAPI.TokenStore` and shared across all managers — reads are
  lock-free; misses funnel through this GenServer.

  ## Async fetch

  `handle_call` records the caller's `from` reference and returns `:noreply`.
  The HTTP fetch runs in a `Task`, and on completion every waiter on that key
  is replied to via `GenServer.reply/2`. This means a slow fetch cannot block
  the mailbox — a burst of concurrent callers on a cold cache still triggers
  exactly one upstream token request per key.

  ## Proactive refresh

  After a successful fetch we schedule an internal `:refresh` message ~30s
  before `expires_at`. If the refresh fetch fails we swallow the error and
  let the next user-initiated call fall through to the normal reactive path.

  ## Marketplace `app_ticket`

  For `app_type: :marketplace`, call `bootstrap/1` explicitly from your
  application startup if you want the SDK to ask Feishu to resend a ticket
  when none is cached. Wire the incoming `app_ticket` event through
  `FeishuOpenAPI.Event.Dispatcher.new/1`'s `:client` option (which
  auto-registers the handler) or manually via `put_app_ticket/2`.

  Keys stored in ETS:

    * `{:tenant, cache_namespace, tenant_key}` — tenant access token (tenant_key is
      `nil` for self-built apps).
    * `{:app, cache_namespace}` — app access token.
    * `{:app_ticket, cache_namespace}` — marketplace app ticket (TTL `:infinity`).
  """

  use GenServer

  require Logger

  alias FeishuOpenAPI.{Client, Error, TokenStore}

  # Treat a token as expired this long before its nominal expiry, so a token is
  # never used right as it lapses (clock skew between hosts, server-side early
  # expiry, in-flight request latency).
  @expiry_delta_ms :timer.minutes(3)
  # Fire the proactive refresh this far ahead of the (already shortened) expiry,
  # so a fresh token is usually warm in ETS before any caller needs it.
  @refresh_lead_ms :timer.seconds(30)
  # Caller-side bound on a token fetch. Must exceed Req's receive timeout so a
  # slow-but-succeeding upstream fetch isn't cut off by the GenServer.call.
  @call_timeout :timer.seconds(15)

  @type key ::
          {:tenant, Client.cache_namespace(), String.t() | nil} | {:app, Client.cache_namespace()}

  # Public API

  @doc false
  @spec start_link(Client.t()) :: GenServer.on_start()
  def start_link(%Client{} = client) do
    GenServer.start_link(__MODULE__, client, name: via_tuple(Client.cache_namespace(client)))
  end

  @doc false
  def child_spec(%Client{} = client) do
    # `:transient` because these processes are started lazily on first cache miss
    # and hold no durable state of their own (tokens live in shared ETS). A clean
    # exit should not be restarted; a crash will be, and the next miss simply
    # refetches. The cache-namespace id keeps one manager per credential set.
    %{
      id: {__MODULE__, Client.cache_namespace(client)},
      start: {__MODULE__, :start_link, [client]},
      restart: :transient,
      type: :worker
    }
  end

  @spec get_tenant_token(Client.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, Error.t()}
  @doc """
  Returns a tenant access token, fetching it through the per-app manager on miss.
  """
  def get_tenant_token(%Client{} = client, tenant_key \\ nil) do
    key = tenant_token_key(client, tenant_key)

    case lookup(key) do
      {:ok, token} -> {:ok, token}
      :miss -> call_manager(client, {:fetch, key})
    end
  end

  @doc """
  Returns an app access token, fetching it through the per-app manager on miss.
  """
  @spec get_app_token(Client.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def get_app_token(%Client{} = client) do
    key = app_token_key(client)

    case lookup(key) do
      {:ok, token} -> {:ok, token}
      :miss -> call_manager(client, {:fetch, key})
    end
  end

  @doc """
  Removes a cached tenant or app token so the next request fetches a fresh one.
  """
  @spec invalidate(Client.t(), :tenant | :app, String.t() | nil) :: :ok
  def invalidate(client, type, tenant_key \\ nil)

  def invalidate(%Client{} = client, :tenant, tenant_key) do
    :ets.delete(TokenStore.table(), tenant_token_key(client, tenant_key))
    :ok
  end

  def invalidate(%Client{} = client, :app, _tenant_key) do
    :ets.delete(TokenStore.table(), app_token_key(client))
    :ok
  end

  @doc """
  Stores the marketplace app_ticket received from Feishu events.
  """
  @spec put_app_ticket(Client.t(), String.t()) :: :ok
  def put_app_ticket(%Client{} = client, ticket) when is_binary(ticket) do
    :ets.insert(TokenStore.table(), {app_ticket_key(client), ticket, :infinity})
    :ok
  end

  @doc """
  Reads the cached marketplace app_ticket without triggering provider calls.
  """
  @spec get_app_ticket(Client.t()) :: {:ok, String.t()} | :miss
  def get_app_ticket(%Client{} = client) do
    case :ets.lookup(TokenStore.table(), app_ticket_key(client)) do
      [{_, ticket, _}] -> {:ok, ticket}
      [] -> :miss
    end
  end

  @doc """
  Drop the cached `app_ticket` for `client`. Intended for the `app_ticket_invalid`
  (code `10012`) recovery path, which is paired with `async_resend_app_ticket/1`.
  """
  @spec invalidate_app_ticket(Client.t()) :: :ok
  def invalidate_app_ticket(%Client{} = client) do
    :ets.delete(TokenStore.table(), app_ticket_key(client))
    :ok
  end

  @doc """
  Marketplace apps only: if no `app_ticket` is cached, ask Feishu to resend one
  asynchronously. Returns `:ok` immediately. No-op for self-built apps.

  Call this once from your application's supervision tree (or on boot) for
  marketplace apps; the SDK no longer fires a resend automatically when the
  per-app `TokenManager` starts.
  """
  @spec bootstrap(Client.t()) :: :ok
  def bootstrap(%Client{app_type: :marketplace} = client) do
    case get_app_ticket(client) do
      {:ok, _ticket} -> :ok
      :miss -> async_resend_app_ticket(client)
    end
  end

  def bootstrap(%Client{}), do: :ok

  @doc """
  Asynchronously ask Feishu to resend the marketplace `app_ticket`. Returns `:ok`
  immediately; the webhook that ships the new ticket is responsible for populating
  the cache via `put_app_ticket/2` (or `Event.Dispatcher` when `client:` is wired up).
  """
  @spec async_resend_app_ticket(Client.t()) :: :ok
  def async_resend_app_ticket(%Client{} = client) do
    _ =
      Task.Supervisor.start_child(FeishuOpenAPI.EventTaskSupervisor, fn ->
        try do
          case FeishuOpenAPI.Auth.app_ticket_resend(client) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("feishu_openapi app_ticket resend failed: #{inspect(reason)}")
          end
        rescue
          exception ->
            Logger.warning(
              "feishu_openapi app_ticket resend crashed: #{Exception.message(exception)}"
            )
        end
      end)

    :ok
  end

  # GenServer callbacks

  @impl true
  def init(%Client{} = client) do
    {:ok,
     %{
       client: client,
       fetches: %{},
       refresh_timers: %{}
     }}
  end

  @impl true
  def handle_call({:fetch, key}, from, state) do
    case lookup(key) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :miss ->
        # Calls for the same cold key are coalesced. The first caller starts the
        # task; later callers wait for the same task result instead of creating
        # a thundering herd against Feishu.
        {:noreply, enqueue_waiter(state, key, from)}
    end
  end

  @impl true
  def handle_info({:refresh, key}, state) do
    state = update_in(state.refresh_timers, &Map.delete(&1, key))

    if Map.has_key?(state.fetches, key) do
      # A user request is already refreshing this key. Starting a second refresh
      # would only add provider load and race with the same cache slot.
      {:noreply, state}
    else
      {:noreply, start_fetch(state, key, [])}
    end
  end

  def handle_info({:fetch_done, key, result}, state) do
    {waiters, fetches} = Map.pop(state.fetches, key, [])
    state = %{state | fetches: fetches}

    # A single in-flight fetch serves everyone queued on this key. Real callers
    # are stored as `{:waiter, from}` and get GenServer.reply'd — this is what
    # deduplicates a concurrent burst into one upstream request. A proactive
    # refresh enqueues an empty waiter list, so this loop just warms the cache
    # without replying to anyone. (`:refresh` is a defensive no-op clause; the
    # bare atom is never actually placed in the waiter list.)
    Enum.each(waiters, fn
      {:waiter, from} -> GenServer.reply(from, client_result(result))
      :refresh -> :ok
    end)

    state =
      case result do
        {:ok, _token, expires_at_ms} when is_integer(expires_at_ms) ->
          schedule_refresh(state, key, expires_at_ms)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Internal

  defp client_result({:ok, token, _expires_at}), do: {:ok, token}
  defp client_result({:error, _} = err), do: err

  defp via_tuple(cache_namespace),
    do: {:via, Registry, {FeishuOpenAPI.TokenRegistry, cache_namespace}}

  defp call_manager(%Client{} = client, message) do
    pid = ensure_started(client)
    GenServer.call(pid, message, @call_timeout)
  end

  defp ensure_started(%Client{} = client) do
    cache_namespace = Client.cache_namespace(client)

    case Registry.lookup(FeishuOpenAPI.TokenRegistry, cache_namespace) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(
               FeishuOpenAPI.TokenManager.Supervisor,
               {__MODULE__, client}
             ) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp lookup(key) do
    case :ets.lookup(TokenStore.table(), key) do
      [{^key, token, :infinity}] ->
        {:ok, token}

      [{^key, token, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, token}
        else
          # Expired rows are deleted on read so later callers take the normal
          # miss path and join a single fetch task.
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

    case Task.Supervisor.start_child(FeishuOpenAPI.EventTaskSupervisor, fn ->
           result = safe_do_fetch(client, key)
           send(parent, {:fetch_done, key, result})
         end) do
      {:ok, _pid} ->
        %{state | fetches: fetches}

      {:error, reason} ->
        send(parent, {:fetch_done, key, {:error, fetch_start_failed_error(client, key, reason)}})
        %{state | fetches: fetches}
    end
  end

  defp do_fetch(%Client{app_type: :self_built} = client, {:tenant, _, _} = key) do
    case FeishuOpenAPI.Auth.tenant_access_token(client) do
      {:ok, %{token: t, expire: e}} -> cache_and_return(key, t, e)
      {:error, _} = err -> err
    end
  end

  defp do_fetch(%Client{app_type: :marketplace}, {:tenant, _, nil}) do
    {:error,
     %Error{code: :tenant_key_required, msg: "marketplace apps require opts[:tenant_key]"}}
  end

  defp do_fetch(%Client{app_type: :marketplace} = client, {:tenant, _, tenant_key} = key) do
    # Marketplace tenant tokens are a two-step chain: an app token proves the app
    # identity, then the tenant key selects the installing organization.
    with {:ok, app_token} <- get_or_fetch_app_token(client),
         {:ok, %{token: t, expire: e}} <-
           FeishuOpenAPI.Auth.tenant_access_token_marketplace(client, app_token, tenant_key) do
      cache_and_return(key, t, e)
    end
  end

  defp do_fetch(%Client{app_type: :self_built} = client, {:app, _} = key) do
    case FeishuOpenAPI.Auth.app_access_token(client) do
      {:ok, %{token: t, expire: e}} -> cache_and_return(key, t, e)
      {:error, _} = err -> err
    end
  end

  defp do_fetch(%Client{app_type: :marketplace} = client, {:app, _} = key) do
    with {:ok, ticket} <- require_app_ticket(client),
         {:ok, %{token: t, expire: e}} <-
           FeishuOpenAPI.Auth.app_access_token_marketplace(client, ticket) do
      cache_and_return(key, t, e)
    end
  end

  defp get_or_fetch_app_token(%Client{} = client) do
    key = app_token_key(client)

    case lookup(key) do
      {:ok, token} -> {:ok, token}
      :miss -> fetch_app_token_sync(client, key)
    end
  end

  defp fetch_app_token_sync(%Client{} = client, key) do
    case do_fetch(client, key) do
      {:ok, token, _expires_at} -> {:ok, token}
      {:error, _} = err -> err
    end
  end

  defp require_app_ticket(client) do
    case get_app_ticket(client) do
      {:ok, ticket} ->
        {:ok, ticket}

      :miss ->
        {:error,
         %Error{
           code: :app_ticket_missing,
           msg:
             "marketplace app_access_token requires an app_ticket; " <>
               "register FeishuOpenAPI.Event.Dispatcher with client: client or call " <>
               "FeishuOpenAPI.TokenManager.put_app_ticket/2 from your app_ticket event handler"
         }}
    end
  end

  defp cache_and_return(key, token, expire_seconds) do
    expires_at =
      System.monotonic_time(:millisecond) + :timer.seconds(expire_seconds) - @expiry_delta_ms

    # The SDK stores a shortened TTL. Feishu tokens can expire slightly earlier
    # than their nominal value, and network time can differ between machines.
    :ets.insert(TokenStore.table(), {key, token, expires_at})
    {:ok, token, expires_at}
  end

  defp schedule_refresh(state, key, expires_at_ms) do
    state = cancel_refresh_timer(state, key)
    delay = expires_at_ms - System.monotonic_time(:millisecond) - @refresh_lead_ms

    # Skip proactive refresh when the lead time already overshoots expiry (very
    # short-lived token). No timer is armed; the next caller takes the reactive
    # miss-and-refetch path instead.
    if delay > 0 do
      timer = Process.send_after(self(), {:refresh, key}, delay)
      %{state | refresh_timers: Map.put(state.refresh_timers, key, timer)}
    else
      state
    end
  end

  defp cancel_refresh_timer(state, key) do
    case Map.pop(state.refresh_timers, key) do
      {nil, _} ->
        state

      {timer, rest} ->
        _ = Process.cancel_timer(timer)
        %{state | refresh_timers: rest}
    end
  end

  defp safe_do_fetch(%Client{} = client, key) do
    do_fetch(client, key)
  rescue
    exception ->
      # Token fetches run in tasks. Converting crashes into Error structs keeps
      # every waiter on the GenServer call path from hanging forever.
      {:error, fetch_crash_error(client, key, :error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, fetch_crash_error(client, key, kind, reason, __STACKTRACE__)}
  end

  defp fetch_crash_error(client, key, kind, reason, stacktrace) do
    %Error{
      code: :token_fetch_crashed,
      msg:
        "token fetch crashed for #{inspect(public_key(key, client))}: " <>
          Exception.format(kind, reason, stacktrace),
      details: {kind, reason}
    }
  end

  defp fetch_start_failed_error(client, key, reason) do
    %Error{
      code: :token_fetch_start_failed,
      msg:
        "token fetch could not start for #{inspect(public_key(key, client))}: #{inspect(reason)}",
      details: reason
    }
  end

  defp public_key({:tenant, _cache_namespace, tenant_key}, %Client{app_id: app_id}),
    do: {:tenant, app_id, tenant_key}

  defp public_key({:app, _cache_namespace}, %Client{app_id: app_id}),
    do: {:app, app_id}

  defp tenant_token_key(%Client{} = client, tenant_key),
    do: {:tenant, Client.cache_namespace(client), tenant_key}

  defp app_token_key(%Client{} = client), do: {:app, Client.cache_namespace(client)}
  defp app_ticket_key(%Client{} = client), do: {:app_ticket, Client.cache_namespace(client)}
end
