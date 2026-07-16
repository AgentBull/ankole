defmodule Ankole.AIGateway.ResponseStream.Supervisor do
  @moduledoc false

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec start_stream(keyword()) :: DynamicSupervisor.on_start_child()
  def start_stream(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Ankole.AIGateway.ResponseStream, opts})
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
