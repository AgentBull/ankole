defmodule Ankole.ActorRuntime.Transport.Broker do
  @moduledoc """
  Owner-facing actor transport broker.

  The production transport route is ZeroMQ; this GenServer keeps the Elixir API
  stable and provides a local route handler for deterministic smoke tests.
  """

  use GenServer

  require Logger

  alias Ankole.ActorRuntime.CommitCoordinator
  alias Ankole.ActorRuntime.WorkerAdmission
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
  Sends one envelope to a transport route.
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

    case start_router_in_state(endpoint, opts, state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("failed to start actor bus router: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:actor_bus_router_received, route, envelope_json}, state) do
    route
    |> decode_router_envelope(envelope_json)
    |> dispatch_router_envelope()

    {:noreply, state}
  end

  def handle_info({:actor_bus_router_decode_failed, route, reason}, state) do
    Logger.warning("actor bus decode failed route=#{inspect(route)} reason=#{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:actor_bus_router_socket_error, reason}, state) do
    Logger.warning("actor bus router socket error: #{inspect(reason)}")
    {:noreply, state}
  end

  defp dispatch(handler, envelope) when is_function(handler, 1), do: handler.(envelope)
  defp dispatch(handler, envelope) when is_pid(handler), do: send(handler, {:actor_bus, envelope})

  defp start_router_in_state(endpoint, opts, %{router: nil} = state) do
    with {:ok, router} <- ActorBus.router_start(endpoint, self(), opts),
         endpoint when is_binary(endpoint) <- ActorBus.router_endpoint(router) do
      {:ok, %{state | router: router, router_endpoint: endpoint}}
    else
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  defp start_router_in_state(_endpoint, _opts, state), do: {:ok, state}

  defp router_send_mandatory(nil, _route, _envelope), do: {:error, :unknown_route}

  defp router_send_mandatory(router, route, envelope) do
    ActorBus.router_send_mandatory(router, route, envelope)
  end

  defp decode_router_envelope(route, envelope_json) do
    {:ok, route, Torque.decode!(envelope_json)}
  rescue
    error -> {:error, route, Exception.message(error)}
  end

  defp dispatch_router_envelope({:ok, route, %{"body" => %{"type" => "worker_ready"} = body}}) do
    WorkerAdmission.admit_worker_ready(body["worker_ready"], %{
      authenticated?: true,
      transport_route: route
    })
    |> log_router_result("worker_ready", route)
  end

  defp dispatch_router_envelope({:ok, route, %{"body" => %{"type" => "worker_heartbeat"} = body}}) do
    WorkerAdmission.handle_worker_heartbeat(body["worker_heartbeat"], %{
      authenticated?: true,
      transport_route: route
    })
    |> log_router_result("worker_heartbeat", route)
  end

  defp dispatch_router_envelope({:ok, route, %{"body" => %{"type" => "worker_capacity"} = body}}) do
    WorkerAdmission.handle_worker_capacity(body["worker_capacity"], %{
      authenticated?: true,
      transport_route: route
    })
    |> log_router_result("worker_capacity", route)
  end

  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "turn_accepted"}} = envelope}
       ) do
    envelope
    |> Ankole.ActorRuntime.handle_turn_accepted()
    |> log_router_result("turn_accepted", route)
  end

  defp dispatch_router_envelope(
         {:ok, route, %{"body" => %{"type" => "turn_final_proposal"}} = envelope}
       ) do
    envelope
    |> CommitCoordinator.commit_final_proposal()
    |> log_router_result("turn_final_proposal", route)
  end

  defp dispatch_router_envelope({:ok, route, %{"body" => %{"type" => "turn_error"}} = envelope}) do
    envelope
    |> CommitCoordinator.handle_turn_error()
    |> log_router_result("turn_error", route)
  end

  defp dispatch_router_envelope({:ok, route, %{"body" => %{"type" => type}}}) do
    Logger.debug("ignored actor bus envelope type=#{type} route=#{inspect(route)}")
  end

  defp dispatch_router_envelope({:error, route, reason}) do
    Logger.warning(
      "failed to decode actor bus envelope route=#{inspect(route)} reason=#{inspect(reason)}"
    )
  end

  defp log_router_result({:ok, _result}, _type, _route), do: :ok

  defp log_router_result({:error, reason}, type, route) do
    Logger.warning(
      "actor bus #{type} handling failed route=#{inspect(route)} reason=#{inspect(reason)}"
    )
  end
end
