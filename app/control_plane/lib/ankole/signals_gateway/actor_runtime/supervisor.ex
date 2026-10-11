defmodule Ankole.SignalsGateway.ActorRuntime.Supervisor do
  @moduledoc """
  Supervision root for control-plane actor-runtime services.

  This supervisor is the failure domain for the actor runtime. It uses
  `:one_for_one`: each child is an independent concern (route directory,
  naming, RPC tasks, and per-conversation drivers), so one crashing
  does not invalidate the others' state. Durable correctness lives in
  PostgreSQL, not in these processes.
  """

  use Supervisor

  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey

  @test_children if Application.compile_env(:ankole, :test_worker_routes, false),
                   do: [Ankole.SignalsGateway.ActorRuntime.LocalWorkerRoutes],
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
      Ankole.SignalsGateway.ActorRuntime.WorkerTracker,
      {Task.Supervisor, name: Ankole.SignalsGateway.ActorRuntime.InboundTaskSupervisor},
      Ankole.Conversations.Supervisor
    ]

    Supervisor.init(children ++ @test_children, strategy: :one_for_one)
  end
end
