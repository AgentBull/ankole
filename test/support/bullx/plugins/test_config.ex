defmodule BullX.Plugins.TestConfig do
  use BullX.Config

  @envdoc false
  bullx_env(:test_plugin_secret,
    key: [:plugins, :test_plugin, :secret],
    type: :binary,
    default: nil,
    secret: true
  )
end
