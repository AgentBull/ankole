defmodule GoogleOpenAPI.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      GoogleOpenAPI.Cache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
