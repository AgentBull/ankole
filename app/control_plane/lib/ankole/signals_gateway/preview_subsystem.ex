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
      {Task.Supervisor, name: Ankole.SignalsGateway.PreviewTaskSupervisor},
      {DynamicSupervisor, name: Ankole.SignalsGateway.PreviewSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
