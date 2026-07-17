defmodule Ankole.SignalsGateway.ActorRuntime.Transport.Broker do
  @moduledoc """
  Owner-facing RuntimeFabric transport broker.

  The production transport route is ZeroMQ; this GenServer keeps the Elixir API
  stable and provides a local route handler for deterministic smoke tests.

  There are two transport routes behind one identical API:

    * Production: a single ZeroMQ ROUTER socket (owned by the native RuntimeFabric)
      reaches every connected worker. A "transport route" is the worker's ROUTER
      identity — the address ZeroMQ uses to deliver an envelope to that worker.
    * Local (test only): an in-process handler (function or pid) registered
      under a route string. This exercises the same envelope decode/dispatch
      code without spinning up a ZeroMQ worker, so smoke tests stay fast and
      deterministic.

  `send_mandatory/2` resolves a route to whichever transport owns it: a local
  route if one is registered, otherwise the production ROUTER. Inbound traffic
  arrives the other way — the native ROUTER forwards decoded envelopes here as
  `:runtime_fabric_router_received` messages, already tagged with the worker
  identity the transport authenticated.

  Keeping the single ROUTER socket behind this one GenServer means every route
  failure surfaces in one place, where it can be turned into a scheduling signal
  instead of a lost actor turn.
  """

  use GenServer

  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Common
  alias Ankole.SignalsGateway.ActorRuntime.FileTransferLane
  alias Ankole.SignalsGateway.ActorRuntime.InboundDispatcher
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey

  @type handler :: (FabricProto.Envelope.t() -> term()) | pid()
  @default_rpc_timeout_ms 60_000
  @router_retry_base_ms 250
  @router_retry_max_ms 5_000

  @doc """
  Starts the broker.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Registers a local route handler.

  Local routes are a test-only transport shortcut. They exercise the same
  envelope handling code without requiring a ZeroMQ worker process.
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
  Starts the ZeroMQ ROUTER transport owned by this broker.

  Binding the native socket is a synchronous NIF call, so we cap the GenServer
  call at 5s: long enough for a normal `bind()` plus ZAP setup, short enough that
  a wedged native layer fails the caller instead of blocking the broker forever.
  """
  @spec start_router(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_router(endpoint, opts \\ []) when is_binary(endpoint) and is_list(opts) do
    GenServer.call(__MODULE__, {:start_router, endpoint, opts}, 5_000)
  end

  @doc """
  Stops the ZeroMQ ROUTER transport if it is running.

  Same 5s bound as `start_router/2` — closing the native socket is a blocking
  NIF call and should not be able to hang the broker indefinitely.
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
  Sends one envelope to a transport route.

  The send is mandatory from the control-plane point of view: an unknown route
  must become a scheduling signal, not a silently dropped actor turn.
  """
  @spec send_mandatory(String.t(), FabricProto.Envelope.t()) ::
          {:ok, :sent_or_queued} | {:error, :unknown_route | term()}
  def send_mandatory(transport_route, %FabricProto.Envelope{} = envelope)
      when is_binary(transport_route) do
    try do
      # The native RouterHandle owns the configurable command timeout. This
      # call only waits its turn in the socket-owning process and must not add a
      # second, unrelated deadline above that transport contract.
      GenServer.call(__MODULE__, {:send_mandatory, transport_route, envelope}, :infinity)
    catch
      :exit, _reason -> {:error, :broker_unavailable}
    end
  end

  @doc """
  Sends a control-plane-originated RPC request to one worker route.

  The RPC lane is bidirectional, but each call still has one caller, one callee,
  and one `request_id`. This function owns the control-plane caller side and
  resolves when the worker sends `rpc_response` or `rpc_error` back on the same
  route.
  """
  @spec request_rpc(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def request_rpc(transport_route, method, payload \\ %{}, opts \\ [])
      when is_binary(transport_route) and is_binary(method) and is_map(payload) and
             is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_rpc_timeout_ms)

    GenServer.call(
      __MODULE__,
      {:request_rpc, transport_route, method, payload, opts},
      timeout_ms + 1_000
    )
  end

  @doc """
  Sends one raw worker-file frame set to a transport route.

  This is intentionally separate from `send_mandatory/2`: actor/rpc envelopes
  are protobuf control traffic, while worker-file frames carry binary chunks.
  """
  @spec send_file_frame(String.t(), [binary()]) ::
          {:ok, :sent_or_queued} | {:error, :unknown_route | term()}
  def send_file_frame(transport_route, frames)
      when is_binary(transport_route) and is_list(frames) do
    try do
      # FileTransferLane owns the whole-operation deadline; RouterHandle owns
      # the per-command transport deadline. The broker queue is not a third
      # timeout boundary.
      GenServer.call(__MODULE__, {:send_file_frame, transport_route, frames}, :infinity)
    catch
      :exit, _reason -> {:error, :broker_unavailable}
    end
  end

  @impl true
  def init(opts) do
    state = %{
      local_routes: %{},
      router: nil,
      router_endpoint: nil,
      router_config: nil,
      router_retry_attempt: 0,
      router_retry_timer: nil,
      rpc_waiters: %{}
    }

    # Bind the ROUTER in a continuation, not inline in init/1: binding is a
    # blocking NIF call, and deferring it keeps the supervisor's start_link fast
    # and lets a bind failure be logged (see handle_continue) instead of
    # crash-looping the whole actor-runtime supervisor at boot.
    case Keyword.get(opts, :router) do
      nil ->
        {:ok, state}

      false ->
        {:ok, state}

      router_opts ->
        {:ok, %{state | router_config: router_opts}, {:continue, :start_router}}
    end
  end

  @impl true
  def handle_call({:register_local_worker, route, handler}, _from, state) do
    {:reply, :ok, put_in(state, [:local_routes, route], handler)}
  end

  @impl true
  def handle_call({:unregister_local_worker, route}, _from, state) do
    {:reply, :ok, update_in(state.local_routes, &Map.delete(&1, route))}
  end

  @impl true
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
      {:ok, state} ->
        {:reply, {:ok, state.router_endpoint}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, schedule_router_retry(state, reason)}
    end
  end

  @impl true
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

  @impl true
  def handle_call(:router_endpoint, _from, %{router_endpoint: nil} = state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call(:router_endpoint, _from, state) do
    {:reply, {:ok, state.router_endpoint}, state}
  end

  @impl true
  def handle_call({:send_mandatory, route, envelope}, _from, state) do
    {:reply, send_envelope_to_route(route, envelope, state), state}
  end

  @impl true
  def handle_call({:request_rpc, route, method, payload, opts}, from, state) do
    request_id = request_id(opts)
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_rpc_timeout_ms)
    timer = Process.send_after(self(), {:rpc_request_timeout, request_id}, timeout_ms)
    envelope = rpc_request_envelope(request_id, method, payload, timeout_ms)
    waiter = %{from: from, route: route, method: method, timer: timer}
    state = put_in(state, [:rpc_waiters, request_id], waiter)

    case send_envelope_to_route(route, envelope, state) do
      {:ok, :sent_or_queued} ->
        {:noreply, state}

      {:error, reason} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, reason})
        {:noreply, update_in(state.rpc_waiters, &Map.delete(&1, request_id))}
    end
  end

  @impl true
  def handle_call({:send_file_frame, route, frames}, _from, state) do
    case Map.fetch(state.local_routes, route) do
      {:ok, handler} ->
        dispatch_file_frame(handler, frames)
        {:reply, {:ok, :sent_or_queued}, state}

      :error ->
        {:reply, router_send_file_frame(state.router, route, frames), state}
    end
  end

  @impl true
  def handle_continue(:start_router, state) do
    case start_configured_router(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        {:noreply, schedule_router_retry(state, reason)}
    end
  end

  @impl true
  def handle_info(:retry_router_start, state) do
    state = %{state | router_retry_timer: nil}

    case start_configured_router(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        {:noreply, schedule_router_retry(state, reason)}
    end
  end

  @impl true
  # The native ROUTER forwards inbound frames in two shapes. The 3-tuple is the
  # unauthenticated form (ZAP disabled, e.g. in tests): route + validated
  # protobuf bytes only. The 5-tuple is the production form: the transport has
  # already verified the worker's ZAP pre-auth key and sends
  # worker_id/key_revision as authentication metadata for the route.
  # `key_revision` is an auth-boundary fact even though the current global
  # worker key only has revision 1.
  def handle_info({:runtime_fabric_router_received, route, envelope_bytes}, state) do
    handle_router_received_safely(route, nil, nil, envelope_bytes, state)
  end

  def handle_info(
        {:runtime_fabric_router_received, route, authenticated_worker_id,
         authenticated_key_revision, envelope_bytes},
        state
      ) do
    handle_router_received_safely(
      route,
      normalize_auth_worker_id(authenticated_worker_id),
      normalize_auth_key_revision(authenticated_key_revision),
      envelope_bytes,
      state
    )
  end

  def handle_info(
        {:runtime_fabric_router_file_frame, route, authenticated_worker_id,
         authenticated_key_revision, frames},
        state
      ) do
    route_auth =
      authenticated_route(
        route,
        normalize_auth_worker_id(authenticated_worker_id),
        normalize_auth_key_revision(authenticated_key_revision)
      )

    FileTransferLane.handle_worker_frame(route_auth, frames)
    {:noreply, state}
  end

  def handle_info({:runtime_fabric_router_decode_failed, route, reason}, state) do
    Logging.warning(
      "runtime_fabric.router_decode_failed",
      "runtime fabric router decode failed",
      %{
        route: route,
        reason: inspect(reason)
      }
    )

    {:noreply, state}
  end

  def handle_info({:runtime_fabric_router_socket_error, reason}, state) do
    Logging.warning("runtime_fabric.router_socket_error", "runtime fabric router socket error", %{
      reason: inspect(reason)
    })

    {:noreply, state}
  end

  @impl true
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
    # The Rustler resource also monitors this process, but stopping here keeps
    # graceful and callback-driven exits deterministic. Both paths are
    # intentionally idempotent so an unexpected Broker failure releases the
    # bind before its supervisor starts the replacement child.
    try do
      _result = RuntimeFabric.router_stop(router)
      _result = WorkerAdmission.mark_all_routes_unusable(:router_stopped)
      :ok
    rescue
      _exception -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  # Entry point for every inbound envelope. This process mutates only transport
  # state: RPC replies resolve its pending callers; every request or domain
  # event is forwarded without executing application code in the ROUTER owner.
  defp handle_router_received_safely(
         route,
         authenticated_worker_id,
         authenticated_key_revision,
         envelope_bytes,
         state
       ) do
    handle_router_received(
      route,
      authenticated_worker_id,
      authenticated_key_revision,
      envelope_bytes,
      state
    )
  rescue
    exception ->
      log_inbound_dispatch_failure(route, :error, exception, __STACKTRACE__)
      {:noreply, state}
  catch
    kind, reason ->
      log_inbound_dispatch_failure(route, kind, reason, __STACKTRACE__)
      {:noreply, state}
  end

  defp handle_router_received(
         route,
         authenticated_worker_id,
         authenticated_key_revision,
         envelope_bytes,
         state
       ) do
    authenticated_route =
      authenticated_route(route, authenticated_worker_id, authenticated_key_revision)

    case decode_router_envelope(route, envelope_bytes) do
      {:ok, route, %FabricProto.Envelope{body: {:rpc_response, response}}} ->
        {:noreply, resolve_rpc_response(state, route, response)}

      {:ok, route, %FabricProto.Envelope{body: {:rpc_error, error}}} ->
        {:noreply, resolve_rpc_error(state, route, error)}

      decoded ->
        InboundDispatcher.dispatch(decoded, authenticated_route)
        {:noreply, state}
    end
  end

  defp log_inbound_dispatch_failure(route, kind, reason, stacktrace) do
    Logging.error(
      "runtime_fabric.inbound_dispatch_failed",
      "runtime fabric inbound dispatch failed",
      %{
        route: route,
        reason: Exception.format(kind, reason, stacktrace)
      }
    )
  end

  # Delivers to a local (test) route handler. A handler may be a 1-arity function
  # (called synchronously) or a pid (gets an `{:actor_lane, envelope}` message),
  # so tests can assert on either a return value or a received message.
  defp dispatch(handler, envelope) when is_function(handler, 1), do: handler.(envelope)

  defp dispatch(handler, envelope) when is_pid(handler),
    do: send(handler, {:actor_lane, envelope})

  defp dispatch_file_frame(handler, frames) when is_function(handler, 1),
    do: handler.({:file_transfer_lane, frames})

  defp dispatch_file_frame(handler, frames) when is_pid(handler),
    do: send(handler, {:file_transfer_lane, frames})

  # Local routes win over the production ROUTER so a test handler can shadow a
  # route. A locally dispatched envelope is always "sent": the handler runs
  # in-process and cannot be lost on the wire.
  defp send_envelope_to_route(route, envelope, state) do
    case Map.fetch(state.local_routes, route) do
      {:ok, handler} ->
        dispatch(handler, envelope)
        {:ok, :sent_or_queued}

      :error ->
        router_send_mandatory(state.router, route, envelope)
    end
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

    %{
      state
      | router_retry_attempt: state.router_retry_attempt + 1,
        router_retry_timer: timer
    }
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
      router_retry_timer: nil
    })
  end

  # Starts the single production ROUTER owned by this broker. Keeping the socket
  # behind one GenServer makes route failure handling visible to ActorRuntime.
  defp start_router_in_state(endpoint, opts, %{router: nil} = state) do
    opts = put_worker_auth_key(opts)

    with {:ok, router} <- RuntimeFabric.router_start(endpoint, self(), opts),
         endpoint when is_binary(endpoint) <- RuntimeFabric.router_endpoint(router) do
      {:ok, %{state | router: router, router_endpoint: endpoint}}
    else
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp start_router_in_state(_endpoint, _opts, state), do: {:ok, state}

  # Reports `unknown_route` when the production router is not running. The
  # caller converts that into worker staleness and retryable deliveries.
  defp router_send_mandatory(nil, _route, _envelope), do: {:error, :unknown_route}

  defp router_send_mandatory(router, route, envelope) do
    RuntimeFabric.router_send_mandatory(router, route, envelope)
  end

  defp router_send_file_frame(nil, _route, _frames), do: {:error, :unknown_route}

  defp router_send_file_frame(router, route, frames) do
    RuntimeFabric.router_send_file_frame(router, route, frames)
  end

  defp resolve_rpc_response(state, route, %FabricProto.RPCResponse{} = response) do
    payload = Common.decode_json_bytes(response.payload_json) || %{}

    resolve_rpc_reply(state, route, response.request_id, {:ok, payload})
  end

  defp resolve_rpc_error(state, route, %FabricProto.RPCError{} = error) do
    error_payload = %{
      "request_id" => error.request_id,
      "code" => error.code,
      "message" => error.message,
      "details_json" => Common.decode_json_bytes(error.details_json) || %{}
    }

    resolve_rpc_reply(state, route, error.request_id, {:error, error_payload})
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
          %{
            request_id: request_id,
            expected_route: other_route,
            route: route,
            operation: rpc_operation(request_id)
          }
        )

        state

      _value ->
        Logging.debug(
          "runtime_fabric.rpc_reply_without_waiter",
          "runtime fabric rpc reply without waiter",
          %{
            request_id: request_id,
            route: route,
            operation: rpc_operation(request_id)
          }
        )

        state
    end
  end

  # Decodes protobuf bytes emitted by the native RuntimeFabric transport with
  # the generated codec. Protocol validation already happened in the kernel.
  defp decode_router_envelope(route, envelope_bytes) do
    case FabricProto.Envelope.decode(envelope_bytes) do
      {:ok, envelope} -> {:ok, route, envelope}
      {:error, reason} -> {:error, route, reason}
    end
  end

  defp rpc_request_envelope(request_id, method, payload, timeout_ms) do
    %FabricProto.Envelope{
      protocol_version: 1,
      message_id: "rpc-request-#{Ecto.UUID.generate()}",
      correlation_id: request_id,
      lane: :LANE_RPC,
      sent_at_unix_ms: System.system_time(:millisecond),
      durability: :CONTROL_EPHEMERAL,
      body:
        {:rpc_request,
         %FabricProto.RPCRequest{
           request_id: request_id,
           method: method,
           deadline_unix_ms: System.system_time(:millisecond) + timeout_ms,
           payload_json: Torque.encode!(payload)
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

  # Same worker-auth defaulting as the supervisor, applied here for callers that
  # start the router directly via start_router/2 without going through the
  # supervisor's config path.
  defp put_worker_auth_key(opts),
    do: Keyword.put_new(opts, :worker_auth_key, WorkerAuthKey.ensure!())

  defp authenticated_route(route, authenticated_worker_id, authenticated_key_revision) do
    %{
      route: route,
      worker_id: authenticated_worker_id,
      key_revision: authenticated_key_revision
    }
  end

  # Collapse "no identity" sentinels from the native layer to nil so downstream
  # auth checks see a clean optional. A blank worker id or a non-positive key
  # revision means the transport did not authenticate this frame (ZAP disabled),
  # not "authenticated as the empty worker".
  defp normalize_auth_worker_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      worker_id -> worker_id
    end
  end

  defp normalize_auth_worker_id(_value), do: nil

  defp normalize_auth_key_revision(value) when is_integer(value) and value > 0, do: value
  defp normalize_auth_key_revision(_value), do: nil

  defp rpc_operation(request_id) when is_binary(request_id) do
    %{id: request_id, producer: "ankole-control-plane/runtime-fabric-rpc"}
  end

  defp rpc_operation(_request_id), do: nil
end
