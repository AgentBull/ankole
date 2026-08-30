defmodule Ankole.Workflow.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Ankole.Workflow.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Ankole.Workflow.RunSupervisor},
      {Task.Supervisor, name: Ankole.Workflow.ReplayTaskSupervisor, max_children: 4}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
