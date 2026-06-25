defmodule Ankole.ActorRuntime.WorkerRegistry do
  @moduledoc """
  Durable worker projection API.

  Thin compatibility facade kept for callers that still reach for a "worker
  registry" name. It delegates straight to `Ankole.ActorRuntime.WorkerAdmission`,
  where the admission rules, identity fencing, and route handling actually live.
  Note this is the *durable* projection (a Postgres table), not the in-process
  `ActorDirectory` Registry used to name session controllers.
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
