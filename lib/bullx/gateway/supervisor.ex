defmodule BullX.Gateway.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = [
      BullX.Gateway.QueueGate
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
