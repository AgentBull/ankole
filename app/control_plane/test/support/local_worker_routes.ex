defmodule Ankole.AgentWorkers.LocalWorkerRoutes do
  @moduledoc """
  Test-only Worker handlers and RPC waiters. Only the test build starts this
  server; routes without a local handler still use the real Worker Channel.
  """

  use GenServer

  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.AgentWorkers.InboundDispatcher
  alias Ankole.AgentWorkers.WorkerRoute

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def register_local_worker(route, handler),
    do: GenServer.call(__MODULE__, {:register_local_worker, route, handler})

  def unregister_local_worker(route),
    do: GenServer.call(__MODULE__, {:unregister_local_worker, route})

  # A fake channel for the real Tracker and cross-node WorkerRoute boundary.
  def start_tracked_channel(worker, owner) do
    Task.Supervisor.start_child(Ankole.Sessions.Tasks, fn ->
      {:ok, _} =
        Phoenix.Tracker.track(
          Ankole.AgentWorkers.WorkerTracker,
          self(),
          WorkerRoute.topic(worker.agent_uid),
          worker.transport_route,
          WorkerRoute.directory_meta(worker.incarnation_id)
        )

      send(owner, {:tracked_channel, self()})
      tracked_channel(owner)
    end)
  end

  defp tracked_channel(owner) do
    receive do
      {:"$gen_call", from, {:deliver, envelope}} ->
        send(owner, {:tracked_delivery, self(), envelope})
        GenServer.reply(from, {:ok, :sent_or_queued})
        tracked_channel(owner)

      {:close_connection, _reason} ->
        :ok
    end
  end

  def call(target, request, timeout_ms, channel_call) do
    route = route_of(target)

    case transport_of(route) do
      {:local, handler} ->
        case request do
          {:request_rpc, envelope, rpc_timeout_ms} ->
            GenServer.call(
              __MODULE__,
              {:request_local_rpc, route, handler, envelope, rpc_timeout_ms},
              timeout_ms
            )

          {_deliver_or_push, envelope} ->
            dispatch(handler, envelope)
            {:ok, :sent_or_queued}
        end

      :channel ->
        channel_call.(target, request, timeout_ms)
    end
  end

  def local_inbound(route, bytes, worker_id) when is_binary(bytes) do
    case Ankole.RuntimeFabric.V1.Envelope.decode(bytes) do
      {:ok, envelope} -> local_inbound(route, envelope, worker_id)
      {:error, reason} -> InboundDispatcher.dispatch({:error, route, reason}, nil, nil)
    end
  end

  def local_inbound(route, %FabricProto.Envelope{} = envelope, worker_id) do
    unless resolve_reply(route, envelope) do
      InboundDispatcher.dispatch(
        {:ok, route, envelope},
        %{transport_route: route, worker_id: worker_id},
        nil
      )
    end

    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{local_routes: %{}, rpc_waiters: %{}}}

  @impl true
  def handle_call({:register_local_worker, route, handler}, _from, state),
    do: {:reply, :ok, put_in(state, [:local_routes, route], handler)}

  def handle_call({:unregister_local_worker, route}, _from, state) do
    state =
      state
      |> update_in([:local_routes], &Map.delete(&1, route))
      |> fail_rpc_waiters_for_route(route)

    {:reply, :ok, state}
  end

  def handle_call({:transport_of, route}, _from, state) do
    transport =
      case Map.fetch(state.local_routes, route) do
        {:ok, handler} -> {:local, handler}
        :error -> :channel
      end

    {:reply, transport, state}
  end

  def handle_call({:request_local_rpc, route, handler, envelope, timeout_ms}, from, state) do
    {:rpc_request, request} = envelope.body
    dispatch(handler, envelope)
    timer = Process.send_after(self(), {:rpc_request_timeout, request.request_id}, timeout_ms)
    waiter = %{from: from, route: route, timer: timer}
    {:noreply, put_in(state, [:rpc_waiters, request.request_id], waiter)}
  end

  @impl true
  def handle_cast({:resolve_rpc, route, request_id, result}, state),
    do: {:noreply, resolve_rpc_reply(state, route, request_id, result)}

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

  defp transport_of(route) do
    GenServer.call(__MODULE__, {:transport_of, route})
  catch
    :exit, _reason -> :channel
  end

  defp dispatch(handler, envelope) when is_function(handler, 1), do: handler.(envelope)

  defp dispatch(handler, envelope) when is_pid(handler),
    do: send(handler, {:actor_lane, envelope})

  defp route_of(%{transport_route: route}), do: route
  defp route_of(route) when is_binary(route), do: route

  defp resolve_reply(route, %FabricProto.Envelope{body: {:rpc_response, response}}) do
    GenServer.cast(
      __MODULE__,
      {:resolve_rpc, route, response.request_id, {:ok, response.payload}}
    )

    true
  end

  defp resolve_reply(route, %FabricProto.Envelope{body: {:rpc_error, error}}) do
    GenServer.cast(
      __MODULE__,
      {:resolve_rpc, route, error.request_id, {:error, WorkerRoute.rpc_error_payload(error)}}
    )

    true
  end

  defp resolve_reply(_route, %FabricProto.Envelope{}), do: false

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

  # A route that goes away fails its waiting callers as a closing Worker
  # Channel does.
  defp fail_rpc_waiters_for_route(state, route) do
    {failed, retained} =
      Enum.split_with(state.rpc_waiters, fn {_id, waiter} -> waiter.route == route end)

    Enum.each(failed, fn {_request_id, waiter} ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, :socket_closed})
    end)

    %{state | rpc_waiters: Map.new(retained)}
  end
end
