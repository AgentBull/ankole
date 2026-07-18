defmodule Ankole.SignalsGateway.ActorRuntime.InboundDispatcher do
  @moduledoc """
  Routes decoded RuntimeFabric traffic above the socket-owning broker.

  Worker lifecycle events are serialized here, actor events are forwarded to
  their per-session controller, and independent worker RPC requests run under a
  task supervisor. No domain callback executes in the transport Broker process.
  """

  use GenServer

  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.ActorLane
  alias Ankole.SignalsGateway.ActorRuntime.RPCLane
  alias Ankole.SignalsGateway.ActorRuntime.SessionController
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission

  @task_supervisor Ankole.SignalsGateway.ActorRuntime.InboundTaskSupervisor

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec dispatch(tuple(), map()) :: :ok
  def dispatch(decoded, authenticated_route) do
    GenServer.cast(__MODULE__, {:dispatch, decoded, authenticated_route})
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:dispatch, decoded, authenticated_route}, state) do
    dispatch_safely(decoded, authenticated_route)
    {:noreply, state}
  end

  defp dispatch_safely(decoded, authenticated_route) do
    dispatch_envelope(decoded, authenticated_route)
  rescue
    exception ->
      log_dispatch_failure(decoded, :error, exception, __STACKTRACE__)
  catch
    kind, reason ->
      log_dispatch_failure(decoded, kind, reason, __STACKTRACE__)
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:rpc_request, request}}},
         _authenticated_route
       ) do
    start_rpc_task(route, request)
  end

  defp dispatch_envelope(
         {:ok, route,
          %FabricProto.Envelope{
            protocol_version: protocol_version,
            body: {:worker_ready, worker_ready}
          }},
         authenticated_route
       ) do
    WorkerAdmission.admit_worker_ready(
      worker_ready,
      route_auth(route, authenticated_route),
      protocol_version
    )
    |> log_result("worker_ready", route)
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:worker_heartbeat, worker_heartbeat}}},
         authenticated_route
       ) do
    WorkerAdmission.handle_worker_heartbeat(
      worker_heartbeat,
      route_auth(route, authenticated_route)
    )
    |> log_result("worker_heartbeat", route)
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:worker_capacity, worker_capacity}}},
         authenticated_route
       ) do
    WorkerAdmission.handle_worker_capacity(
      worker_capacity,
      route_auth(route, authenticated_route)
    )
    |> log_result("worker_capacity", route)
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {type, _payload}} = envelope},
         _authenticated_route
       ) do
    if ActorLane.turn_type?(type) do
      case ActorLane.actor_key(envelope) do
        {:ok, actor_key} ->
          SessionController.dispatch_inbound(actor_key, route, envelope)
          |> log_result(type, route)

        {:error, reason} ->
          log_result({:error, reason}, type, route)
      end
    else
      Logging.debug(
        "runtime_fabric.actor_lane_envelope_ignored",
        "runtime fabric actor lane envelope ignored",
        %{type: type, route: route}
      )
    end
  end

  defp dispatch_envelope({:error, route, reason}, _authenticated_route) do
    Logging.warning(
      "runtime_fabric.actor_lane_decode_failed",
      "runtime fabric actor lane decode failed",
      %{route: route, reason: inspect(reason)}
    )
  end

  defp start_rpc_task(route, request) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           request
           |> RPCLane.handle_request(route)
           |> send_rpc_response(route)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logging.error(
          "runtime_fabric.rpc_dispatch_failed",
          "runtime fabric RPC task could not start",
          %{route: route, reason: inspect(reason)}
        )
    end
  end

  defp send_rpc_response({:ok, response}, route) do
    response
    |> then(&Broker.send_mandatory(route, &1))
    |> log_result("rpc_response", route)
  end

  defp send_rpc_response({:error, reason}, route) do
    log_result({:error, reason}, "rpc_request", route)
  end

  defp route_auth(route, authenticated_route) do
    %{
      authenticated?: true,
      transport_route: route,
      worker_id: authenticated_route.worker_id,
      key_revision: authenticated_route.key_revision
    }
  end

  defp log_result({:ok, _result}, _type, _route), do: :ok

  defp log_result(:ok, _type, _route), do: :ok

  defp log_result({:error, reason}, type, route) do
    Logging.warning(
      "runtime_fabric.inbound_handling_failed",
      "runtime fabric inbound handling failed",
      %{type: type, route: route, reason: inspect(reason)}
    )

    :ok
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
