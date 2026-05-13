defmodule BullX.Plugins do
  @moduledoc """
  Plugin host API.

  The plugin host discovers trusted compile-time plugins, validates their
  declarations, stores extension metadata in a reconstructible registry, and
  starts children for plugins enabled through runtime configuration.
  """

  defdelegate plugins(server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate enabled_plugins(server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate enabled?(id, server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate all_extensions(server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry
  defdelegate extensions_for(point, server \\ BullX.Plugins.Registry), to: BullX.Plugins.Registry

  defdelegate enabled_extensions_for(point, server \\ BullX.Plugins.Registry),
    to: BullX.Plugins.Registry
end
