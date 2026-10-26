defmodule Ankole.Plugins.Cohort do
  @moduledoc """
  Owns one immutable boot snapshot and its supervised Plugin processes.

  The Registry and runtime supervisor form a `:rest_for_one` failure cohort.
  A Registry restart keeps the boot snapshot and restarts every process that
  consumed it. A runtime-child failure stays inside the runtime supervisor.
  """

  use Supervisor

  alias Ankole.Plugins.Registry

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    registry_name = Keyword.get(opts, :registry_name, Registry)

    runtime_supervisor_name =
      Keyword.get(opts, :runtime_supervisor_name, Ankole.Plugins.Supervisor)

    case Registry.prepare_snapshot(opts) do
      {:ok, snapshot} ->
        children = [
          %{
            id: Registry,
            start: {Registry, :start_link, [[name: registry_name, snapshot: snapshot]]}
          },
          {Ankole.Plugins.Supervisor, registry: registry_name, name: runtime_supervisor_name}
        ]

        Supervisor.init(children, strategy: :rest_for_one)

      {:error, reason} ->
        {:stop, reason}
    end
  end
end
