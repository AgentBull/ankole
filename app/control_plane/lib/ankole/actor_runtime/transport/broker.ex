defmodule Ankole.ActorRuntime.Transport.Broker do
  @moduledoc """
  Owner-facing actor transport broker.

  The production transport route is ZeroMQ; this GenServer keeps the Elixir API
  stable and provides a local route handler for deterministic smoke tests.

  There are two transport routes behind one identical API:

    * Production: a single ZeroMQ ROUTER socket (owned by the native Actor Bus)
      reaches every connected worker. A "transport route" is the worker's ROUTER
      identity — the address ZeroMQ uses to deliver an envelope to that worker.
    * Local (test only): an in-process handler (function or pid) registered
      under a route string. This exercises the same envelope decode/dispatch
      code without spinning up a ZeroMQ worker, so smoke tests stay fast and
      deterministic.

  `send_mandatory/2` resolves a route to whichever transport owns it: a local
  route if one is registered, otherwise the production ROUTER. Inbound traffic
  arrives the other way — the native ROUTER forwards decoded envelopes here as
  `:actor_bus_router_received` messages, already tagged with the worker identity
  the transport authenticated.

  Keeping the single ROUTER socket behind this one GenServer means every route
  failure surfaces in one place, where it can be turned into a scheduling signal
  instead of a lost actor turn.
  """

  use GenServer

  require Logger

  alias Ankole.ActorRuntime.CommitCoordinator
  alias Ankole.ActorRuntime.LlmCredentialBroker
  alias Ankole.ActorRuntime.WorkerAdmission
  alias Ankole.ActorRuntime.WorkerAuthKeys
  alias Ankole.Kernel.ActorBus

  @type handler :: (map() -> term()) | pid()

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
  @spec send_mandatory(String.t(), map()) ::
          {:ok, :sent_or_queued} | {:error, :unknown_route | term()}
  def send_mandatory(transport_route, envelope)
      when is_binary(transport_route) and is_map(envelope) do
    GenServer.call(__MODULE__, {:send_mandatory, transport_route, envelope})
  end

  @impl true
  def init(opts) do
    state = %{local_routes: %{}, router: nil, router_endpoint: nil}

    # Bind the ROUTER in a continuation, not inline in init/1: binding is a
    # blocking NIF call, and deferring it keeps the supervisor's start_link fast
    # and lets a bind failure be logged (see handle_continue) instead of
    # crash-looping the whole actor-runtime supervisor at boot.
    case Keyword.get(opts, :router) do
      nil -> {:ok, state}
      false -> {:ok, state}
      router_opts -> {:ok, state, {:continue, {:start_router, router_opts}}}
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
  def handle_call({:start_router, endpoint, opts}, _from, state) do
    case start_router_in_state(endpoint, opts, state) do
      {:ok, state} -> {:reply, {:ok, state.router_endpoint}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:stop_router, _from, %{router: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:stop_router, _from, %{router: router} = state) do
    reply = ActorBus.router_stop(router)
    {:reply, reply, %{state | router: nil, router_endpoint: nil}}
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
    # Local routes win over the production ROUTER so a test handler can shadow a
    # route. A locally dispatched envelope is always "sent": the handler runs
    # in-process and cannot be lost on the wire.
    case Map.fetch(state.local_routes, route) do
      {:ok, handler} ->
        dispatch(handler, envelope)
        {:reply, {:ok, :sent_or_queued}, state}

      :error ->
        {:reply, router_send_mandatory(state.router, route, envelope), state}
    end
  end

  @impl true
  def handle_continue({:start_router, router_opts}, state) do
    endpoint = Keyword.fetch!(router_opts, :endpoint)
    opts = Keyword.delete(router_opts, :endpoint)

    # A failed bind at boot logs and leaves the broker running with no router:
    # the process stays up so operators can retry via start_router/2 (e.g. after
    # freeing the port), rather than crash-looping the whole runtime supervisor.
    # With no router, send_mandatory/2 reports :unknown_route, which the caller
    # treats as worker staleness — outbound turns stay durable and retryable.
    case start_router_in_state(endpoint, opts, state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("failed to start actor bus router: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  # The native ROUTER forwards inbound frames in two shapes. The 3-tuple is the
  # unauthenticated form (ZAP disabled, e.g. in tests): route + raw JSON only.
  # The 5-tuple is the production form: the transport has already verified the
  # worker's pre-auth key and tells us which worker_id / key_revision the route
  # belongs to, so lifecycle messages can be bound to a proven identity below.
  def handle_info({:actor_bus_router_received, route, envelope_json}, state) do
    handle_router_received(route, nil, nil, envelope_json, state)
  end

  def handle_info(
        {:actor_bus_router_received, route, authenticated_worker_id, authenticated_key_revision,
         envelope_json},
        state
      ) do
    handle_router_received(
      route,
      normalize_auth_worker_id(authenticated_worker_id),
      normalize_auth_key_revision(authenticated_key_revision),
      envelope_json,
      state
    )
  end

  def handle_info({:actor_bus_router_decode_failed, route, reason}, state) do
    Logger.warning("actor bus decode failed route=#{inspect(route)} reason=#{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:actor_bus_router_socket_error, reason}, state) do
    Logger.warning("actor bus router socket error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Entry point for every inbound envelope. The LLM-credential request is the one
  # request/response RPC on this socket: a worker asks the control plane to mint
  # provider credentials and waits for the reply on the same route, so it is
  # answered inline and the response is sent straight back. Everything else is
  # one-way (lifecycle projections, turn results) and goes through
  # dispatch_router_envelope/2, which never replies on the socket.
  defp handle_router_received(
         route,
         authenticated_worker_id,
         authenticated_key_revision,
         envelope_json,
         state
       ) do
    authenticated_route =
      authenticated_route(route, authenticated_worker_id, authenticated_key_revision)

    case decode_router_envelope(route, envelope_json) do
      {:ok, route, %{"body" => %{"type" => "llm_provider_credential_request"} = body}} ->
        body["llm_provider_credential_request"]
        |> LlmCredentialBroker.handle_request(route)
        |> send_rpc_response(state.router, route)

      decoded ->
        dispatch_router_envelope(decoded, authenticated_route)
    end

    {:noreply, state}
  end

  # Delivers to a local (test) route handler. A handler may be a 1-arity function
  # (called synchronously) or a pid (gets an `{:actor_bus, envelope}` message),
  # so tests can assert on either a return value or a received message.
  defp dispatch(handler, envelope) when is_function(handler, 1), do: handler.(envelope)
  defp dispatch(handler, envelope) when is_pid(handler), do: send(handler, {:actor_bus, envelope})

  # Starts the single production ROUTER owned by this broker. Keeping the socket
  # behind one GenServer makes route failure handling visible to ActorRuntime.
  defp start_router_in_state(endpoint, opts, %{router: nil} = state) do
    opts = maybe_database_worker_auth(opts)

    with {:ok, router} <- ActorBus.router_start(endpoint, self(), opts),
         endpoint when is_binary(endpoint) <- ActorBus.router_endpoint(router) do
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
    ActorBus.router_send_mandatory(router, route, envelope)
  end

  defp send_rpc_response({:ok, response}, router, route) do
    router
    |> router_send_mandatory(route, response)
    |> log_router_result("llm_provider_credential_response", route)
  end

  defp send_rpc_response({:error, reason}, _router, route) do
    Logger.warning(
      "actor bus llm_provider_credential_request handling failed route=#{inspect(route)} reason=#{inspect(reason)}"
    )
  end

  # Decodes the JSON host representation emitted by the native Actor Bus
  # transport. Protocol validation already happened in kernel encode/decode.
  defp decode_router_envelope(route, envelope_json) do
    {:ok, route, Torque.decode!(envelope_json)}
  rescue
    error -> {:error, route, Exception.message(error)}
  end

  # Lifecycle envelopes are authenticated by the route they arrived on, then
  # projected into the worker table for scheduling.
  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "worker_ready"} = body}},
         authenticated_route
       ) do
    WorkerAdmission.admit_worker_ready(body["worker_ready"], %{
      authenticated?: true,
      transport_route: route,
      worker_id: authenticated_route.worker_id,
      key_revision: authenticated_route.key_revision
    })
    |> log_router_result("worker_ready", route)
  end

  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "worker_heartbeat"} = body}},
         authenticated_route
       ) do
    WorkerAdmission.handle_worker_heartbeat(body["worker_heartbeat"], %{
      authenticated?: true,
      transport_route: route,
      worker_id: authenticated_route.worker_id,
      key_revision: authenticated_route.key_revision
    })
    |> log_router_result("worker_heartbeat", route)
  end

  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "worker_capacity"} = body}},
         authenticated_route
       ) do
    WorkerAdmission.handle_worker_capacity(body["worker_capacity"], %{
      authenticated?: true,
      transport_route: route,
      worker_id: authenticated_route.worker_id,
      key_revision: authenticated_route.key_revision
    })
    |> log_router_result("worker_capacity", route)
  end

  # Worker turn envelopes go back through the public runtime API so local routes
  # and ZeroMQ routes share exactly the same commit and retry behavior.
  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "turn_accepted"}} = envelope},
         _authenticated_route
       ) do
    envelope
    |> Ankole.ActorRuntime.handle_turn_accepted()
    |> log_router_result("turn_accepted", route)
  end

  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "turn_final_proposal"}} = envelope},
         _authenticated_route
       ) do
    envelope
    |> CommitCoordinator.commit_final_proposal()
    |> log_router_result("turn_final_proposal", route)
  end

  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "turn_error"}} = envelope},
         _authenticated_route
       ) do
    envelope
    |> CommitCoordinator.handle_turn_error()
    |> log_router_result("turn_error", route)
  end

  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => type}}},
         _authenticated_route
       ) do
    Logger.debug("ignored actor bus envelope type=#{type} route=#{inspect(route)}")
  end

  defp dispatch_router_envelope({:error, route, reason}, _authenticated_route) do
    Logger.warning(
      "failed to decode actor bus envelope route=#{inspect(route)} reason=#{inspect(reason)}"
    )
  end

  # Same ZAP-auth defaulting as the supervisor, applied here for callers that
  # start the router directly via start_router/2 (e.g. tests) without going
  # through the supervisor's config path. Unless the caller supplies its own
  # credentials, point the native router at the Repo database so it can verify
  # worker pre-auth keys.
  defp maybe_database_worker_auth(opts) do
    cond do
      Keyword.has_key?(opts, :pre_auth_token) ->
        Keyword.delete(opts, :worker_auth)

      Keyword.has_key?(opts, :pre_auth_keys) ->
        Keyword.delete(opts, :worker_auth)

      Keyword.has_key?(opts, :worker_auth_database_url) ->
        Keyword.delete(opts, :worker_auth)

      Keyword.get(opts, :worker_auth, :database) == false ->
        Keyword.delete(opts, :worker_auth)

      true ->
        opts
        |> Keyword.delete(:worker_auth)
        |> Keyword.put(:worker_auth_database_url, WorkerAuthKeys.database_url!())
    end
  end

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

  defp log_router_result({:ok, _result}, _type, _route), do: :ok

  defp log_router_result({:error, reason}, type, route) do
    Logger.warning(
      "actor bus #{type} handling failed route=#{inspect(route)} reason=#{inspect(reason)}"
    )
  end
end
