defmodule Ankole.Plugins.Supervisor do
  @moduledoc """
  Starts supervised children contributed by active plugins.
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
  def init(opts) do
    registry = Keyword.get(opts, :registry, Ankole.Plugins.Registry)
    children = Ankole.Plugins.Registry.supervised_children(registry)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
