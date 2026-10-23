defmodule Ankole.ControlPlanePlugins.Console do
  @moduledoc "Console configuration of Control Plane Plugins."
  use Ash.Resource,
    domain: Ankole.ControlPlanePlugins,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  resource do
    require_primary_key?(false)
  end

  json_api do
    type("control_plane_plugin_console")
    derive_filter?(false)
    derive_sort?(false)
  end

  actions do
    action :list, Ankole.ControlPlanePlugins.ConsoleTypes.ControlPlanePluginListResponse do
      transaction?(false)
      run(__MODULE__.Actions)
    end

    action :configure, Ankole.ControlPlanePlugins.ConsoleTypes.ControlPlanePluginListResponse do
      transaction?(false)
      argument(:id, :string, allow_nil?: false)
      argument(:enabled, :boolean, allow_nil?: false)
      run(__MODULE__.Actions)
    end
  end
end
