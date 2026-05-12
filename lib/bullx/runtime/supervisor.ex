defmodule BullX.Runtime.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(:ok) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
