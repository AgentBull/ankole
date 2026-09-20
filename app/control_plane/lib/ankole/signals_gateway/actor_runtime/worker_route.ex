defmodule Ankole.SignalsGateway.ActorRuntime.WorkerRoute do
  @moduledoc """
  Single exit for control-plane messages to Workers.

  Two physical transports exist during the migration, and each Worker uses
  exactly one:

    * Worker Channel. The transport route is the `connection_id` of one
      channel. The route directory is
      `Ankole.SignalsGateway.ActorRuntime.WorkerTracker`: each admitted
      channel tracks itself under the topic `worker/<scope>/<worker_id>` with
      its `connection_id` as the key. The `scope` is fixed to `installation`;
      it is the namespace a future multi-tenant deployment would vary.
    * ZeroMQ. The transport route is the DEALER identity that ZAP proved.
      This process owns the one native ROUTER and remembers every route that
      spoke on it. ZeroMQ stays only until every Worker has switched; a send
      on it keeps the old meaning of `{:ok, :sent_or_queued}` (queued on the
      socket, no acknowledgement).

  A send follows one path:

    1. A local (test only) route wins over both transports.
    2. A route that spoke on the ROUTER goes to ZeroMQ.
    3. Otherwise look the route up with `Phoenix.Tracker.get_by_key/3`.
    4. Check the entry's `incarnation_id` and `connection_id` against the
       current PostgreSQL route fence; a stale entry is `:stale_route`.
    5. Call the channel process directly, on this node or over Distributed
       Erlang, and wait for the Worker's explicit acknowledgement. No PubSub
       broadcast enters the Worker command path.
    6. A route in neither directory falls back to the ROUTER when one is
       running, because a ZeroMQ Worker that reconnected after a control-plane
       restart is known to the socket before it is known here.
    7. An empty directory, a stale entry, or a missing acknowledgement is an
       error; the caller keeps its durable delivery and never changes durable
       state from a directory result.
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.InboundDispatcher
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerTracker

  @scope "installation"
  @type handler :: (FabricProto.Envelope.t() -> term()) | pid()
  @type target :: %{worker_id: String.t(), transport_route: String.t()} | String.t()
  @default_rpc_timeout_ms 60_000
  @deliver_timeout_ms 15_000
  @router_retry_base_ms 250
  @router_retry_max_ms 5_000

  @doc """
  Starts the route exit. `router:` opts bind the ZeroMQ ROUTER; without them
  only the Worker Channel and local routes exist.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Returns the fixed route namespace.
  """
  @spec scope() :: String.t()
  def scope, do: @scope

  @doc """
  Returns the tracker topic of one Worker.
  """
  @spec topic(String.t(), String.t()) :: String.t()
  def topic(scope \\ @scope, worker_id) when is_binary(scope) and is_binary(worker_id),
    do: "worker/" <> scope <> "/" <> worker_id

  @doc """
  Returns the tracker metadata one admitted channel registers.
  """
  @spec directory_meta(String.t(), String.t(), String.t()) :: map()
  def directory_meta(worker_id, incarnation_id, connection_id) do
    %{
      worker_id: worker_id,
      incarnation_id: incarnation_id,
      connection_id: connection_id,
      channel_pid: self(),
      node: node()
    }
  end

  @doc """
  Registers a local route handler.

  Local routes are a test-only transport shortcut. They exercise the same
  envelope handling code without a Worker Channel or a ZeroMQ socket.
  """
  @spec register_local_worker(String.t(), handler()) :: :ok
  def register_local_worker(transport_route, handler) when is_binary(transport_route) do
    GenServer.call(__MODULE__, {:register_local_worker, transport_route, handler})
  end

  @doc """
  Removes a local route handler.
  """
  @spec unregister_local_worker(String.t()) :: :ok
  def unregister_local_worker(transport_route) when is_binary(transport_route) do
    GenServer.call(__MODULE__, {:unregister_local_worker, transport_route})
  end

  @doc """
  Starts the ZeroMQ ROUTER transport owned by this process.

  Binding the native socket is a synchronous NIF call, so the call is capped at
  5 s: long enough for a normal `bind()` plus ZAP setup, short enough that a
  wedged native layer fails the caller instead of blocking the route exit.
  """
  @spec start_router(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_router(endpoint, opts \\ []) when is_binary(endpoint) and is_list(opts) do
    GenServer.call(__MODULE__, {:start_router, endpoint, opts}, 5_000)
  end

  @doc """
  Stops the ZeroMQ ROUTER transport if it is running.
  """
  @spec stop_router() :: :ok | {:error, term()}
  def stop_router do
    GenServer.call(__MODULE__, :stop_router, 5_000)
  end

  @doc """
  Returns the bound ZeroMQ endpoint when the ROUTER is running.
  """
  @spec router_endpoint() :: {:ok, String.t()} | {:error, :not_started}
  def router_endpoint do
    GenServer.call(__MODULE__, :router_endpoint)
  end

  @doc """
  Feeds one Worker envelope into the inbound path on behalf of a local route.

  Tests use this in place of a Worker connection: an `rpc_response` or
  `rpc_error` resolves the RPC waiter, everything else reaches the inbound
  dispatcher exactly as a transport message does.
  """
  @spec local_inbound(String.t(), FabricProto.Envelope.t() | binary()) :: :ok
  def local_inbound(transport_route, envelope_bytes)
      when is_binary(transport_route) and is_binary(envelope_bytes) do
    case RuntimeFabric.decode_envelope(envelope_bytes) do
      {:ok, envelope} -> local_inbound(transport_route, envelope)
      {:error, reason} -> InboundDispatcher.dispatch({:error, transport_route, reason}, nil, nil)
    end
  end

  def local_inbound(transport_route, %FabricProto.Envelope{} = envelope)
      when is_binary(transport_route) do
    inbound(transport_route, nil, envelope)
  end

  @doc """
  Sends one command envelope to a transport route.

  The send is mandatory from the control-plane point of view: an unknown route
  must become a scheduling signal, not a silently dropped actor turn. Over the
  Worker Channel `{:ok, :sent_or_queued}` means the Worker acknowledged the
  command; over ZeroMQ it means the socket queued it.
  """
  @spec send_mandatory(target(), FabricProto.Envelope.t()) ::
          {:ok, :sent_or_queued}
          | {:error, :unknown_route | :stale_route | :backpressure | :timeout | term()}
  def send_mandatory(target, %FabricProto.Envelope{} = envelope) do
    route = route_of(target)

    case transport_of(route) do
      {:local, handler} ->
        dispatch(handler, envelope)
        {:ok, :sent_or_queued}

      :zmq ->
        router_call({:router_send, route, envelope})

      :channel ->
        with {:error, :unknown_route} <-
               channel_call(target, {:deliver, envelope}, @deliver_timeout_ms) do
          router_call({:router_send, route, envelope})
        end
    end
  end

  @doc """
  Sends one reply envelope to a transport route without waiting for an acknowledgement.

  RPC responses and errors are answers to Worker requests; the Worker repeats
  a request whose answer it never sees.
  """
  @spec push(target(), FabricProto.Envelope.t()) ::
          {:ok, :sent_or_queued} | {:error, :unknown_route | :stale_route | term()}
  def push(target, %FabricProto.Envelope{} = envelope) do
    route = route_of(target)

    case transport_of(route) do
      {:local, handler} ->
        dispatch(handler, envelope)
        {:ok, :sent_or_queued}

      :zmq ->
        router_call({:router_send, route, envelope})

      :channel ->
        with {:error, :unknown_route} <-
               channel_call(target, {:push, envelope}, @deliver_timeout_ms) do
          router_call({:router_send, route, envelope})
        end
    end
  end

  @doc """
  Sends a control-plane-originated RPC request to one worker route.

  Each call has one caller, one callee, and one `request_id`. This function
  owns the control-plane caller side and resolves when the worker sends
  `rpc_response` or `rpc_error` back on the same route.
  """
  @spec request_rpc(target(), String.t(), binary(), keyword()) ::
          {:ok, binary()} | {:error, map() | term()}
  def request_rpc(target, method, payload \\ <<>>, opts \\ [])
      when is_binary(method) and is_binary(payload) and is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_rpc_timeout_ms)
    request_id = request_id(opts)
    envelope = rpc_request_envelope(request_id, method, payload, timeout_ms)
    route = route_of(target)

    waiting_call = {:request_waiting_rpc, route, envelope, method, timeout_ms}

    case transport_of(route) do
      {:local, _handler} ->
        GenServer.call(__MODULE__, waiting_call, timeout_ms + 1_000)

      :zmq ->
        GenServer.call(__MODULE__, waiting_call, timeout_ms + 1_000)

      :channel ->
        with {:error, :unknown_route} <-
               channel_call(target, {:request_rpc, envelope, timeout_ms}, timeout_ms + 1_000) do
          GenServer.call(__MODULE__, waiting_call, timeout_ms + 1_000)
        end
    end
  end

  @doc """
  Fails RPC callers that are waiting on one local or ZeroMQ route after that route becomes unusable.

  Channel waiters end with their channel process.
  """
  @spec fail_pending_rpcs(String.t(), term()) :: :ok
  def fail_pending_rpcs(transport_route, reason) when is_binary(transport_route) do
    GenServer.cast(__MODULE__, {:fail_pending_rpcs, transport_route, reason})
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Builds the error result shape shared by channel, ZeroMQ, and local RPC waiters.
  """
  @spec rpc_error_payload(FabricProto.RPCError.t()) :: map()
  def rpc_error_payload(%FabricProto.RPCError{} = error) do
    %{
      "request_id" => error.request_id,
      "code" => error.code,
      "message" => error.message,
      "details_json" => Common.decode_json_bytes(error.details_json) || %{}
    }
  end

  @impl true
  def init(opts) do
    state = %{
      local_routes: %{},
      zmq_routes: MapSet.new(),
      router: nil,
      router_endpoint: nil,
      router_config: nil,
      router_retry_attempt: 0,
      router_retry_timer: nil,
      rpc_waiters: %{}
    }

    # Binding is a blocking NIF call. A continuation keeps the supervisor's
    # start fast and lets a bind failure retry instead of crash-looping the
    # actor-runtime supervisor at boot.
    case Keyword.get(opts, :router) do
      router_opts when is_list(router_opts) and router_opts != [] ->
        {:ok, %{state | router_config: router_opts}, {:continue, :start_router}}

      _none ->
        {:ok, state}
    end
  end

  @impl true
  def handle_call({:register_local_worker, route, handler}, _from, state) do
    {:reply, :ok, put_in(state, [:local_routes, route], handler)}
  end

  def handle_call({:unregister_local_worker, route}, _from, state) do
    state =
      state
      |> update_in([:local_routes], &Map.delete(&1, route))
      |> fail_rpc_waiters_for_route(route, :local_route_unregistered)

    {:reply, :ok, state}
  end

  def handle_call({:transport_of, route}, _from, state) do
    transport =
      case Map.fetch(state.local_routes, route) do
        {:ok, handler} -> {:local, handler}
        :error -> if MapSet.member?(state.zmq_routes, route), do: :zmq, else: :channel
      end

    {:reply, transport, state}
  end

  def handle_call({:start_router, _endpoint, _opts}, _from, %{router: router} = state)
      when not is_nil(router) do
    {:reply, {:ok, state.router_endpoint}, state}
  end

  def handle_call({:start_router, endpoint, opts}, _from, state) do
    state =
      state
      |> cancel_router_retry()
      |> Map.merge(%{
        router_config: Keyword.put(opts, :endpoint, endpoint),
        router_retry_attempt: 0
      })

    case start_configured_router(state) do
      {:ok, state} -> {:reply, {:ok, state.router_endpoint}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, schedule_router_retry(state, reason)}
    end
  end

  def handle_call(:stop_router, _from, %{router: nil} = state) do
    {:reply, :ok, disable_router(state)}
  end

  def handle_call(:stop_router, _from, %{router: router} = state) do
    reply =
      with :ok <- RuntimeFabric.router_stop(router),
           {:ok, _stale_workers} <- WorkerAdmission.mark_all_routes_unusable(:router_stopped) do
        :ok
      end

    {:reply, reply, disable_router(state)}
  end

  def handle_call(:router_endpoint, _from, %{router_endpoint: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call(:router_endpoint, _from, state) do
    {:reply, {:ok, state.router_endpoint}, state}
  end

  def handle_call({:router_send, route, envelope}, _from, state) do
    {:reply, router_send_mandatory(state.router, route, envelope), state}
  end

  def handle_call({:request_waiting_rpc, route, envelope, method, timeout_ms}, from, state) do
    {:rpc_request, request} = envelope.body

    send_result =
      case Map.fetch(state.local_routes, route) do
        {:ok, handler} ->
          dispatch(handler, envelope)
          {:ok, :sent_or_queued}

        :error ->
          router_send_mandatory(state.router, route, envelope)
      end

    case send_result do
      {:ok, :sent_or_queued} ->
        timer = Process.send_after(self(), {:rpc_request_timeout, request.request_id}, timeout_ms)
        waiter = %{from: from, route: route, method: method, timer: timer}
        {:noreply, put_in(state, [:rpc_waiters, request.request_id], waiter)}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast({:fail_pending_rpcs, route, reason}, state) do
    {:noreply, fail_rpc_waiters_for_route(state, route, reason)}
  end

  def handle_cast({:resolve_rpc, route, request_id, result}, state) do
    {:noreply, resolve_rpc_reply(state, route, request_id, result)}
  end

  @impl true
  def handle_continue(:start_router, state) do
    case start_configured_router(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, schedule_router_retry(state, reason)}
    end
  end

  @impl true
  def handle_info(:retry_router_start, state) do
    state = %{state | router_retry_timer: nil}

    case start_configured_router(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, schedule_router_retry(state, reason)}
    end
  end

  # The native ROUTER forwards inbound frames in two shapes. The 3-tuple is the
  # unauthenticated form (ZAP disabled, e.g. in tests). The 4-tuple is the
  # production form: the transport verified the worker's ZAP key and names
  # the worker as authentication metadata for the route.
  def handle_info({:runtime_fabric_router_received, route, envelope_bytes}, state) do
    {:noreply, router_received(route, nil, envelope_bytes, state)}
  end

  def handle_info(
        {:runtime_fabric_router_received, route, authenticated_worker_id, envelope_bytes},
        state
      ) do
    {:noreply,
     router_received(
       route,
       normalize_auth_worker_id(authenticated_worker_id),
       envelope_bytes,
       state
     )}
  end

  def handle_info({:runtime_fabric_router_decode_failed, route, reason}, state) do
    Logging.warning(
      "runtime_fabric.router_decode_failed",
      "runtime fabric router decode failed",
      %{route: route, reason: inspect(reason)}
    )

    {:noreply, state}
  end

  def handle_info({:runtime_fabric_router_socket_error, reason}, state) do
    Logging.warning("runtime_fabric.router_socket_error", "runtime fabric router socket error", %{
      reason: inspect(reason)
    })

    {:noreply, state}
  end

  def handle_info({:rpc_request_timeout, request_id}, state) do
    case Map.pop(state.rpc_waiters, request_id) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        GenServer.reply(waiter.from, {:error, :timeout})
        {:noreply, %{state | rpc_waiters: waiters}}
    end
  end

  @impl true
  def terminate(_reason, %{router: nil}), do: :ok

  def terminate(_reason, %{router: router}) do
    # Losing the control-plane observer is not evidence that a Worker died.
    # Keep its turn fences intact; the next router gives existing Workers one
    # normal heartbeat lease to reconnect before the stale-worker path decides.
    try do
      _result = RuntimeFabric.router_stop(router)
      :ok
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp transport_of(route) do
    GenServer.call(__MODULE__, {:transport_of, route})
  catch
    :exit, _reason -> :channel
  end

  defp router_call(request) do
    GenServer.call(__MODULE__, request, @deliver_timeout_ms)
  catch
    :exit, _reason -> {:error, :unknown_route}
  end

  # Delivers to a local (test) route handler. A handler may be a 1-arity function
  # (called synchronously) or a pid (gets an `{:actor_lane, envelope}` message),
  # so tests can assert on either a return value or a received message.
  defp dispatch(handler, envelope) when is_function(handler, 1), do: handler.(envelope)

  defp dispatch(handler, envelope) when is_pid(handler),
    do: send(handler, {:actor_lane, envelope})

  # A bare route names a local or ZeroMQ route; a channel target carries the
  # worker id, because the directory topic is per Worker.
  defp route_of(%{transport_route: route}) when is_binary(route), do: route
  defp route_of(route) when is_binary(route), do: route

  defp channel_call(%{worker_id: worker_id, transport_route: route}, request, timeout_ms)
       when is_binary(worker_id) and is_binary(route) do
    with {:ok, pid} <- route_member(worker_id, route) do
      try do
        GenServer.call(pid, request, timeout_ms)
      catch
        :exit, {:noproc, _call} -> {:error, :unknown_route}
        :exit, {:normal, _call} -> {:error, :unknown_route}
        :exit, {:shutdown, _call} -> {:error, :unknown_route}
        :exit, {{:shutdown, _reason}, _call} -> {:error, :unknown_route}
        :exit, {:timeout, _call} -> {:error, :timeout}
        :exit, {{:nodedown, _node}, _call} -> {:error, :unknown_route}
      end
    end
  end

  defp channel_call(_route, _request, _timeout_ms), do: {:error, :unknown_route}

  # The directory names a process; PostgreSQL decides whether that process
  # still owns the route. A directory entry that does not match the current
  # fence only fails this send and never changes durable state.
  defp route_member(worker_id, route) do
    case Phoenix.Tracker.get_by_key(WorkerTracker, topic(worker_id), route) do
      [] ->
        {:error, :unknown_route}

      entries ->
        case current_fence(worker_id) do
          %{transport_route: ^route, incarnation_id: incarnation_id} ->
            entries
            |> Enum.filter(fn {_pid, meta} ->
              meta.connection_id == route and meta.incarnation_id == incarnation_id
            end)
            |> Enum.sort_by(fn {pid, _meta} -> node(pid) != node() end)
            |> case do
              [{pid, _meta} | _rest] -> {:ok, pid}
              [] -> {:error, :stale_route}
            end

          _fence ->
            {:error, :stale_route}
        end
    end
  end

  defp current_fence(worker_id) do
    Repo.one(
      from(worker in AgentComputerWorker,
        where: worker.worker_id == ^worker_id and worker.status in ["ready", "draining"],
        select: %{transport_route: worker.transport_route, incarnation_id: worker.incarnation_id}
      )
    )
  end

  # Entry point for every inbound ZeroMQ envelope. This process mutates only
  # transport state: RPC replies resolve its pending callers; every request or
  # domain event is forwarded without executing application code here.
  defp router_received(route, authenticated_worker_id, envelope_bytes, state) do
    state = %{state | zmq_routes: MapSet.put(state.zmq_routes, route)}

    case RuntimeFabric.decode_envelope(envelope_bytes) do
      {:ok, envelope} ->
        inbound(route, authenticated_worker_id, envelope)

      {:error, reason} ->
        InboundDispatcher.dispatch({:error, route, reason}, nil, nil)
    end

    state
  rescue
    exception ->
      log_inbound_dispatch_failure(route, :error, exception, __STACKTRACE__)
      state
  catch
    kind, reason ->
      log_inbound_dispatch_failure(route, kind, reason, __STACKTRACE__)
      state
  end

  defp inbound(route, authenticated_worker_id, %FabricProto.Envelope{} = envelope) do
    case envelope.body do
      {:rpc_response, response} ->
        GenServer.cast(
          __MODULE__,
          {:resolve_rpc, route, response.request_id, {:ok, response.payload}}
        )

      {:rpc_error, error} ->
        GenServer.cast(
          __MODULE__,
          {:resolve_rpc, route, error.request_id, {:error, rpc_error_payload(error)}}
        )

      _body ->
        InboundDispatcher.dispatch(
          {:ok, route, envelope},
          %{route: route, worker_id: authenticated_worker_id},
          nil
        )
    end

    :ok
  end

  defp normalize_auth_worker_id(""), do: nil
  defp normalize_auth_worker_id(worker_id) when is_binary(worker_id), do: worker_id
  defp normalize_auth_worker_id(_other), do: nil

  defp log_inbound_dispatch_failure(route, kind, reason, stacktrace) do
    Logging.error(
      "runtime_fabric.inbound_dispatch_failed",
      "runtime fabric inbound dispatch failed",
      %{route: route, reason: Exception.format(kind, reason, stacktrace)}
    )
  end

  defp start_configured_router(%{router: router} = state) when not is_nil(router) do
    {:ok, reset_router_retry(state)}
  end

  defp start_configured_router(%{router_config: nil} = state) do
    {:ok, reset_router_retry(state)}
  end

  defp start_configured_router(%{router_config: router_config} = state) do
    endpoint = Keyword.fetch!(router_config, :endpoint)
    opts = Keyword.delete(router_config, :endpoint)

    case start_router_in_state(endpoint, opts, state) do
      {:ok, state} -> {:ok, reset_router_retry(state)}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp schedule_router_retry(%{router_retry_timer: timer} = state, _reason)
       when not is_nil(timer),
       do: state

  defp schedule_router_retry(state, reason) do
    retry_in_ms = router_retry_delay(state.router_retry_attempt)

    Logging.error(
      "runtime_fabric.router_start_failed",
      "runtime fabric router start failed",
      %{
        reason: inspect(reason),
        retry_attempt: state.router_retry_attempt + 1,
        retry_in_ms: retry_in_ms
      }
    )

    timer = Process.send_after(self(), :retry_router_start, retry_in_ms)
    %{state | router_retry_attempt: state.router_retry_attempt + 1, router_retry_timer: timer}
  end

  defp router_retry_delay(attempt) do
    multiplier = Integer.pow(2, min(attempt, 5))
    min(@router_retry_base_ms * multiplier, @router_retry_max_ms)
  end

  defp reset_router_retry(state) do
    state
    |> cancel_router_retry()
    |> Map.merge(%{router_retry_attempt: 0, router_retry_timer: nil})
  end

  defp cancel_router_retry(%{router_retry_timer: nil} = state), do: state

  defp cancel_router_retry(%{router_retry_timer: timer} = state) do
    Process.cancel_timer(timer, async: true, info: false)
    %{state | router_retry_timer: nil}
  end

  defp disable_router(state) do
    state
    |> cancel_router_retry()
    |> Map.merge(%{
      router: nil,
      router_endpoint: nil,
      router_config: nil,
      router_retry_attempt: 0,
      router_retry_timer: nil,
      zmq_routes: MapSet.new()
    })
  end

  # Starts the single production ROUTER owned by this process. Keeping the
  # socket behind one GenServer makes route failure handling visible to
  # ActorRuntime. Rust receives only the current in-memory auth key.
  defp start_router_in_state(endpoint, opts, %{router: nil} = state) do
    opts = Keyword.put_new_lazy(opts, :worker_auth_key, &WorkerAuthKey.ensure!/0)
    now = DateTime.utc_now(:microsecond)

    with {:ok, _renewed_workers} <-
           WorkerAdmission.renew_worker_leases_for_router_recovery(now),
         {:ok, router} <- RuntimeFabric.router_start(endpoint, self(), opts),
         endpoint when is_binary(endpoint) <- RuntimeFabric.router_endpoint(router) do
      {:ok, %{state | router: router, router_endpoint: endpoint}}
    else
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp start_router_in_state(_endpoint, _opts, state), do: {:ok, state}

  # Reports `unknown_route` when the ROUTER is not running. The caller converts
  # that into worker staleness and retryable deliveries.
  defp router_send_mandatory(nil, _route, _envelope), do: {:error, :unknown_route}

  defp router_send_mandatory(router, route, envelope) do
    RuntimeFabric.router_send_mandatory(router, route, envelope)
  end

  defp resolve_rpc_reply(state, route, request_id, result) do
    with request_id when is_binary(request_id) and request_id != "" <- request_id,
         %{route: ^route} = waiter <- Map.get(state.rpc_waiters, request_id) do
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, result)
      update_in(state.rpc_waiters, &Map.delete(&1, request_id))
    else
      %{route: other_route} ->
        Logging.warning(
          "runtime_fabric.rpc_reply_route_mismatch",
          "runtime fabric rpc reply route mismatch",
          %{request_id: request_id, expected_route: other_route, route: route}
        )

        state

      _value ->
        Logging.debug(
          "runtime_fabric.rpc_reply_without_waiter",
          "runtime fabric rpc reply without waiter",
          %{request_id: request_id, route: route}
        )

        state
    end
  end

  defp fail_rpc_waiters_for_route(state, route, reason) do
    {failed, retained} =
      Enum.split_with(state.rpc_waiters, fn {_request_id, waiter} ->
        waiter.route == route
      end)

    Enum.each(failed, fn {_request_id, waiter} ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, {:worker_route_unusable, reason}})
    end)

    %{state | rpc_waiters: Map.new(retained)}
  end

  @doc false
  @spec rpc_request_envelope(String.t(), String.t(), binary(), pos_integer()) ::
          FabricProto.Envelope.t()
  def rpc_request_envelope(request_id, method, payload, timeout_ms) do
    %FabricProto.Envelope{
      message_id: "rpc-request-#{Ecto.UUID.generate()}",
      correlation_id: request_id,
      sent_at_unix_ms: System.system_time(:millisecond),
      body:
        {:rpc_request,
         %FabricProto.RPCRequest{
           request_id: request_id,
           method: method,
           deadline_unix_ms: System.system_time(:millisecond) + timeout_ms,
           payload: payload
         }}
    }
  end

  defp request_id(opts) do
    case Keyword.get(opts, :request_id) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> "rpc-#{Ecto.UUID.generate()}"
          request_id -> request_id
        end

      _value ->
        "rpc-#{Ecto.UUID.generate()}"
    end
  end
end
