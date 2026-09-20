defmodule Ankole.SignalsGateway.ActorRuntime.InboundDispatcher do
  @moduledoc """
  Routes decoded RuntimeFabric traffic above the Worker Channel.

  Worker lifecycle events are serialized here, actor events are forwarded to
  their per-session controller, and independent worker RPC requests run under a
  task supervisor. No domain callback executes in a channel process. Every
  message carries a `Transport.Reply` handle; the process that completes the
  message answers the Worker through it.
  """

  use GenServer

  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.ActorLane
  alias Ankole.SignalsGateway.ActorRuntime.RPCLane
  alias Ankole.SignalsGateway.ActorRuntime.SessionController
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Reply
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission

  @task_supervisor Ankole.SignalsGateway.ActorRuntime.InboundTaskSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec dispatch(tuple(), map() | nil, Reply.t()) :: :ok
  def dispatch(decoded, authenticated_route, reply_to) do
    GenServer.cast(__MODULE__, {:dispatch, decoded, authenticated_route, reply_to})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:dispatch, decoded, authenticated_route, reply_to}, state) do
    dispatch_safely(decoded, authenticated_route, reply_to)
    {:noreply, state}
  end

  defp dispatch_safely(decoded, authenticated_route, reply_to) do
    dispatch_envelope(decoded, authenticated_route, reply_to)
  rescue
    exception ->
      log_dispatch_failure(decoded, :error, exception, __STACKTRACE__)
      Reply.done(reply_to, {:error, :dispatch_failed})
  catch
    kind, reason ->
      log_dispatch_failure(decoded, kind, reason, __STACKTRACE__)
      Reply.done(reply_to, {:error, :dispatch_failed})
  end

  # The transport answer for a request means "accepted into the bounded
  # in-flight set"; the RPC response is the durable answer.
  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:rpc_request, request}}},
         authenticated_route,
         reply_to
       ) do
    Reply.done(reply_to, start_rpc_task(route, reply_target(route, authenticated_route), request))
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:worker_ready, worker_ready}}},
         authenticated_route,
         reply_to
       ) do
    WorkerAdmission.admit_worker_ready(worker_ready, route_auth(route, authenticated_route))
    |> log_result("worker_ready", route)
    |> then(&Reply.done(reply_to, &1))
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:worker_heartbeat, worker_heartbeat}}},
         authenticated_route,
         reply_to
       ) do
    WorkerAdmission.handle_worker_heartbeat(
      worker_heartbeat,
      route_auth(route, authenticated_route)
    )
    |> log_result("worker_heartbeat", route)
    |> then(&Reply.done(reply_to, &1))
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:worker_capacity, worker_capacity}}},
         authenticated_route,
         reply_to
       ) do
    WorkerAdmission.handle_worker_capacity(
      worker_capacity,
      route_auth(route, authenticated_route)
    )
    |> log_result("worker_capacity", route)
    |> then(&Reply.done(reply_to, &1))
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:control_shutdown, control_shutdown}}},
         authenticated_route,
         reply_to
       ) do
    WorkerAdmission.handle_control_shutdown(
      control_shutdown,
      route_auth(route, authenticated_route)
    )
    |> log_result("control_shutdown", route)
    |> then(&Reply.done(reply_to, &1))
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {type, _payload}} = envelope},
         _authenticated_route,
         reply_to
       ) do
    if ActorLane.turn_type?(type) do
      case ActorLane.actor_key(envelope) do
        {:ok, actor_key} ->
          case SessionController.dispatch_inbound(actor_key, route, envelope, reply_to) do
            :ok ->
              :ok

            {:error, reason} = error ->
              log_result(error, type, route)
              Reply.done(reply_to, {:error, reason})
          end

        {:error, reason} = error ->
          log_result(error, type, route)
          Reply.done(reply_to, {:error, reason})
      end
    else
      Logging.debug(
        "runtime_fabric.actor_lane_envelope_ignored",
        "runtime fabric actor lane envelope ignored",
        %{type: type, route: route}
      )

      Reply.done(reply_to, {:error, :unsupported_envelope})
    end
  end

  defp dispatch_envelope({:error, route, reason}, _authenticated_route, reply_to) do
    Logging.warning(
      "runtime_fabric.actor_lane_decode_failed",
      "runtime fabric actor lane decode failed",
      %{route: route, reason: inspect(reason)}
    )

    Reply.done(reply_to, {:error, :invalid_envelope})
  end

  defp start_rpc_task(route, target, request) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           request
           |> RPCLane.handle_request(route)
           |> send_rpc_response(target)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logging.error(
          "runtime_fabric.rpc_dispatch_failed",
          "runtime fabric RPC task could not start",
          %{route: route, reason: inspect(reason)}
        )

        {:error, :rpc_task_unavailable}
    end
  end

  defp send_rpc_response({:ok, response}, target) do
    response
    |> then(&WorkerRoute.push(target, &1))
    |> log_result("rpc_response", route_of(target))
  end

  defp send_rpc_response({:error, reason}, target) do
    log_result({:error, reason}, "rpc_request", route_of(target))
  end

  # A channel route needs its worker id to be found in the directory; a local
  # test route is addressed by its string alone.
  defp reply_target(route, %{worker_id: worker_id}) when is_binary(worker_id),
    do: %{worker_id: worker_id, transport_route: route}

  defp reply_target(route, _authenticated_route), do: route

  defp route_of(%{transport_route: route}), do: route
  defp route_of(route), do: route

  defp route_auth(route, authenticated_route) do
    %{
      authenticated?: true,
      transport_route: route,
      worker_id: authenticated_route && Map.get(authenticated_route, :worker_id)
    }
  end

  defp log_result({:ok, _result} = result, _type, _route), do: result

  defp log_result(:ok, _type, _route), do: :ok

  defp log_result({:error, reason} = error, type, route) do
    Logging.warning(
      "runtime_fabric.inbound_handling_failed",
      "runtime fabric inbound handling failed",
      %{type: type, route: route, reason: inspect(reason)}
    )

    error
  end

  defp log_dispatch_failure(decoded, kind, reason, stacktrace) do
    route = if is_tuple(decoded) and tuple_size(decoded) == 3, do: elem(decoded, 1), else: nil

    Logging.error(
      "runtime_fabric.inbound_dispatch_failed",
      "runtime fabric inbound dispatch failed",
      %{route: route, reason: Exception.format(kind, reason, stacktrace)}
    )
  end
end
