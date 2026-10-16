defmodule Ankole.Sessions.SessionLane do
  @moduledoc """
  Routes authenticated Job and environment messages to the current Driver.
  Environment messages do not read storage: the Driver matches the run and
  pending call, and Fence rejects closed inputs at the next durable write.
  Job messages keep their persisted attempt check.
  """
  alias Ankole.Sessions.RunRef
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.AgentWorkers.WorkerRouteAuth

  @job_types [:turn_accepted, :worker_progress]
  @workspace_types [:workspace_ready, :tool_status, :tool_progress, :tool_result]
  def turn_type?(type), do: type in @job_types or type in @workspace_types
  def workspace_type?(type), do: type in @workspace_types

  def handle(%Proto.Envelope{body: {type, payload}}, %{worker_id: uid}) when type in @job_types do
    with {:ok, ref} <- JobTurnRef.from_proto(payload.turn, uid),
         :ok <- WorkerRouteAuth.authorize_turn(ref, uid, :read),
         do: forward(ref, type, payload)
  end

  def handle(%Proto.Envelope{body: {type, payload}}, %{worker_id: uid})
      when type in @workspace_types do
    with {:ok, ref} <- RunRef.from_proto(payload.run, uid), do: forward(ref, type, payload)
  end

  def handle(_envelope, _connection), do: {:error, :unsupported_envelope}

  defp forward(ref, type, payload) do
    case Ankole.Sessions.driver_pid(%{agent_uid: ref.agent_uid, session_id: ref.session_id}) do
      :undefined ->
        :ok

      pid ->
        send(pid, {:worker, type, payload})
        :ok
    end
  end
end
