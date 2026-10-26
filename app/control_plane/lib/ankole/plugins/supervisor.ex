defmodule Ankole.Plugins.Supervisor do
  @moduledoc """
  Static supervisor for the children active plugins contribute.

  It asks the registry for the active plugins' child specs once at startup and
  supervises them under `:one_for_one`. Because that list is read in `init/1`,
  the set of plugin children is fixed for the process lifetime — the same boot
  snapshot the registry uses (see `Ankole.Plugins.Registry`). This is why it
  starts after the registry in the application boot order.
  """

  use Supervisor

  @doc """
  Starts the plugin supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  @spec init(keyword()) :: {:ok, tuple()} | :ignore
  def init(opts) do
    registry = Keyword.get(opts, :registry, Ankole.Plugins.Registry)
    children = Ankole.Plugins.Registry.supervised_children(registry)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
