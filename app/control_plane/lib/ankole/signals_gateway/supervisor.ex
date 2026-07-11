defmodule Ankole.SignalsGateway.Supervisor do
  @moduledoc """
  Supervision root for SignalsGateway preview and actor-runtime services.

  SignalsGateway is the failure domain for provider-facing preview handlers and
  the actor runtime. The sibling subtrees restart independently; durable state
  and recovery fences remain in PostgreSQL.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, tuple()}
  def init(opts) do
    actor_runtime_opts = Keyword.get(opts, :actor_runtime, [])

    children = [
      Ankole.SignalsGateway.PreviewSubsystem,
      {Ankole.SignalsGateway.ActorRuntime.Supervisor, actor_runtime_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
