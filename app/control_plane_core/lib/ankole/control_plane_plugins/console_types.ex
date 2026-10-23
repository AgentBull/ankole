defmodule Ankole.ControlPlanePlugins.ConsoleTypes.ControlPlanePluginItem do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        active: [type: :boolean, allow_nil?: false],
        configured_enabled: [type: :boolean, allow_nil?: false],
        description: [type: Ankole.Ash.Types.JSONValue, allow_nil?: false],
        display_name: [type: Ankole.Ash.Types.JSONValue, allow_nil?: false],
        id: [type: :string, allow_nil?: false],
        restart_required: [type: :boolean, allow_nil?: false]
      ],
      preserve_nil_values?: true
    ]
end

defmodule Ankole.ControlPlanePlugins.ConsoleTypes.ControlPlanePluginListResponse do
  @moduledoc false
  use Ash.Type.NewType,
    subtype_of: :map,
    constraints: [
      fields: [
        control_plane_plugins: [
          type: {:array, Ankole.ControlPlanePlugins.ConsoleTypes.ControlPlanePluginItem},
          allow_nil?: false
        ]
      ],
      preserve_nil_values?: true
    ]
end
