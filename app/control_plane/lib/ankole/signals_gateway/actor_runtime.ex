defmodule Ankole.SignalsGateway.ActorRuntime do
  @moduledoc "Worker connections and conversation input entry points."
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAdmission
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentWorker
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}
  @doc """
  Admits the Worker process behind an authenticated Channel join.
  """
  @spec admit_join(map(), WorkerAdmission.auth()) ::
          {:ok, AgentWorker.t()} | {:error, term()}
  defdelegate admit_join(join_payload, auth), to: WorkerAdmission

  @doc """
  Renews the Worker row from an authenticated heartbeat.
  """
  @spec handle_worker_heartbeat(
          FabricProto.AgentComputerWorkerHeartbeat.t(),
          WorkerAdmission.auth()
        ) ::
          {:ok, AgentWorker.t()} | {:error, term()}
  defdelegate handle_worker_heartbeat(worker_heartbeat, auth), to: WorkerAdmission
end
