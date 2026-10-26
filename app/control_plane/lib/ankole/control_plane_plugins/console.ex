defmodule Ankole.ControlPlanePlugins.Console do
  @moduledoc "Console configuration of Control Plane Plugins."
  use Ankole.Ash.OperationResource,
    authorizers: [Ankole.AuthZ.Authorizer],
    domain: Ankole.ControlPlanePlugins,
    data_layer: Ash.DataLayer.Simple,
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:list, resource: "site_console:control_plane_plugins", action: "read")
    allow(:configure, resource: "site_console:control_plane_plugins", action: "update")
  end

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
