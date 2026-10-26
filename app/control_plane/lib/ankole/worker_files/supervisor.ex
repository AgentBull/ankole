defmodule Ankole.WorkerFiles.Supervisor do
  @moduledoc """
  Supervision root for worker-file relay sessions.

  A relay session is transient in-memory state for one file operation. The
  registry addresses a session by its transfer id, and the task supervisor
  runs the control-plane side of a `worker_files.push` RPC while the caller
  consumes the relayed bytes.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Ankole.WorkerFiles.RelayRegistry},
      {DynamicSupervisor, name: Ankole.WorkerFiles.RelaySupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: Ankole.WorkerFiles.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
