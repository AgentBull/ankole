defmodule BullX.Plugins.PluginSupervisor do
  @moduledoc false

  use Supervisor

  def start_link({plugin, context}) do
    Supervisor.start_link(__MODULE__, {plugin, context})
  end

  @impl true
  def init({plugin, context}) do
    plugin.module.children(context)
    |> Supervisor.init(strategy: :one_for_one)
  end
end
