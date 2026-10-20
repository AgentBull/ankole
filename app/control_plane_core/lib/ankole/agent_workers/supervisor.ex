defmodule Ankole.AgentWorkers.Supervisor do
  @moduledoc """
  Supervision root for control-plane actor-runtime services.

  This supervisor is the failure domain for the actor runtime. It uses
  `:one_for_one`: each child is an independent concern (route directory,
  naming, RPC tasks, and per-session drivers), so one crashing
  does not invalidate the others' state. Durable correctness lives in
  PostgreSQL, not in these processes.
  """

  use Supervisor

  alias Ankole.AgentWorkers.WorkerAuthKey

  @test_children if Application.compile_env(:ankole, :test_worker_routes, false),
                   do: [Ankole.AgentWorkers.LocalWorkerRoutes],
                   else: []

  @doc """
  Starts actor-runtime services.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, tuple()} | :ignore
  def init(_opts) do
    WorkerAuthKey.ensure!()

    children = [
      Ankole.AgentWorkers.WorkerTracker,
      {Task.Supervisor, name: Ankole.AgentWorkers.InboundTaskSupervisor}
    ]

    Supervisor.init(children ++ @test_children, strategy: :one_for_one)
  end
end
