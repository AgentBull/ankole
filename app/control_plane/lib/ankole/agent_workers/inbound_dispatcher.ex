defmodule Ankole.AgentWorkers.InboundDispatcher do
  @moduledoc "Dispatches lifecycle and environment messages in each Channel; Job messages and RPC use supervised tasks."

  alias Ankole.Logging
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Sessions.SessionLane
  alias Ankole.Sessions.RPCLane
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.Sessions.Transport.Reply
  alias Ankole.AgentWorkers.WorkerAdmission

  @task_supervisor Ankole.AgentWorkers.InboundTaskSupervisor

  @spec dispatch(tuple(), map() | nil, Reply.t()) :: :ok
  def dispatch(decoded, connection, reply_to),
    do: dispatch_envelope(decoded, connection, reply_to)

  # The transport answer for a request means "accepted into the bounded
  # in-flight set"; the RPC response is the durable answer.
  defp dispatch_envelope(
         {:ok, _route, %FabricProto.Envelope{body: {:rpc_request, request}}},
         connection,
         reply_to
       ) do
    result = start_rpc_task(connection, request, reply_to)
    if match?({:error, _}, result), do: rpc_failed(reply_to, request.request_id)
    Reply.done(reply_to, result)
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:worker_heartbeat, worker_heartbeat}}},
         connection,
         reply_to
       ) do
    WorkerAdmission.handle_worker_heartbeat(
      worker_heartbeat,
      connection
    )
    |> log_result("worker_heartbeat", route)
    |> then(&Reply.done(reply_to, &1))
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {:control_shutdown, control_shutdown}}},
         connection,
         reply_to
       ) do
    WorkerAdmission.handle_control_shutdown(
      control_shutdown,
      connection
    )
    |> log_result("control_shutdown", route)
    |> then(&Reply.done(reply_to, &1))
  end

  defp dispatch_envelope(
         {:ok, route, %FabricProto.Envelope{body: {type, _payload}} = envelope},
         connection,
         reply_to
       ) do
    cond do
      SessionLane.workspace_type?(type) ->
        Reply.done(reply_to, SessionLane.handle(envelope, connection))

      SessionLane.turn_type?(type) ->
        case Task.Supervisor.start_child(
               @task_supervisor,
               Ankole.Repo.bind_tenant(fn ->
                 Reply.done(reply_to, safely(fn -> SessionLane.handle(envelope, connection) end))
               end)
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> Reply.done(reply_to, {:error, reason})
        end

      true ->
        Logging.debug(
          "runtime_fabric.actor_lane_envelope_ignored",
          "runtime fabric actor lane envelope ignored",
          %{type: type, route: route}
        )

        Reply.done(reply_to, {:error, :unsupported_envelope})
    end
  end

  defp dispatch_envelope({:error, route, reason}, _connection, reply_to) do
    Logging.warning(
      "runtime_fabric.actor_lane_decode_failed",
      "runtime fabric actor lane decode failed",
      %{route: route, reason: inspect(reason)}
    )

    Reply.done(reply_to, {:error, :invalid_envelope})
  end

  # The connection is also the reply target: a local test route is found by
  # its route, a channel route by its worker id and route.
  defp start_rpc_task(connection, request, reply_to) do
    route = connection.transport_route

    case Task.Supervisor.start_child(
           @task_supervisor,
           Ankole.Repo.bind_tenant(fn ->
             result =
               safely(fn ->
                 request
                 |> RPCLane.handle_request(connection)
                 |> send_rpc_response(connection)
               end)

             if match?({:error, _}, result), do: rpc_failed(reply_to, request.request_id)
           end)
         ) do
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

  defp safely(fun) do
    fun.()
  catch
    kind, reason ->
      Logging.error(
        "runtime_fabric.inbound_task_failed",
        "Worker request task failed",
        Logging.failure_fields(kind, reason, __STACKTRACE__)
      )

      {:error, :inbound_task_failed}
  end

  defp rpc_failed(nil, _request_id), do: :ok

  defp rpc_failed(%{channel: channel}, request_id) do
    send(channel, {:rpc_failed, request_id})
    :ok
  end

  defp send_rpc_response({:ok, response}, connection) do
    response
    |> then(&WorkerRoute.push(connection, &1))
    |> log_result("rpc_response", connection.transport_route)
  end

  defp send_rpc_response({:error, reason}, connection) do
    log_result({:error, reason}, "rpc_request", connection.transport_route)
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
end
