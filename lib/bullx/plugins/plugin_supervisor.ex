defmodule BullX.Plugins.PluginSupervisor do
  @moduledoc """
  Supervises runtime children contributed by one enabled plugin.

  Plugin children run under their own subtree so a plugin can own local process
  failures without changing BullX's core supervision boundaries.
  """

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
