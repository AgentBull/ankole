defmodule Ankole.FunctionRuntime.Supervisor do
  @moduledoc "Supervises clients of the stateless function runtime."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        {Finch,
         name: Ankole.FunctionRuntime.Finch,
         pools: %{default: [protocols: [:http1], conn_opts: [transport_opts: [inet6: true]]]}},
        {Task.Supervisor, name: Ankole.FunctionRuntime.Tasks},
        Ankole.FunctionRuntime.EndpointPool,
        Ankole.FunctionRuntime.ProgramRunner
      ],
      strategy: :one_for_one
    )
  end
end
