defmodule Ankole.ActorRuntime.WorkerRegistry do
  @moduledoc """
  Durable worker projection API.
  """

  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.ActorRuntime.WorkerAdmission

  @doc """
  Records or refreshes the durable projection for one ready computer worker.

  This module is the small compatibility facade for callers that still name the
  worker registry directly. Admission rules and route fencing live in
  `Ankole.ActorRuntime.WorkerAdmission`.
  """
  @spec record_worker_ready(map(), String.t() | nil) ::
          {:ok, AgentComputerWorker.t()} | {:error, term()}
  defdelegate record_worker_ready(attrs, route \\ nil), to: WorkerAdmission
end
