defmodule Ankole.SignalsGateway.PreviewSubsystem do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec init(keyword()) :: {:ok, tuple()}
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Ankole.SignalsGateway.PreviewRegistry},
      {DynamicSupervisor, name: Ankole.SignalsGateway.PreviewSupervisor, strategy: :one_for_one}
    ]

    # A preview handler registers through PreviewRegistry only once at startup.
    # If the registry is replaced, its sibling handlers must be rebuilt too.
    Supervisor.init(children, strategy: :one_for_all)
  end
end
