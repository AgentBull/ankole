defmodule Ankole.PluginFixtures.DuplicateAlphaPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "alpha"
end
