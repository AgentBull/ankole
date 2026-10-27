defmodule Ankole.FunctionRuntime.Supervisor do
  @moduledoc "Supervises clients of the stateless function runtime."
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    config = Application.fetch_env!(:ankole, :function_runtime)
    hostname = config |> Keyword.fetch!(:url) |> URI.parse() |> Map.fetch!(:host)

    Supervisor.init(
      [
        {Finch,
         name: Ankole.FunctionRuntime.Finch,
         pools: %{
           default: [
             protocols: [:http1],
             conn_opts: [hostname: hostname, transport_opts: [inet6: true]]
           ]
         }},
        {Task.Supervisor, name: Ankole.FunctionRuntime.Tasks},
        Ankole.FunctionRuntime.EndpointPool,
        Ankole.FunctionRuntime.ProgramRunner
      ],
      strategy: :one_for_one
    )
  end
end
