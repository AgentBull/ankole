defmodule BullX.Config.Plugins do
  @moduledoc """
  Runtime configuration consumed by the plugin host.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:enabled_plugins,
    type: BullX.Config.StringList,
    default: []
  )
end
