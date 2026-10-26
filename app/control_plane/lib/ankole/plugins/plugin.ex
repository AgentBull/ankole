defmodule Ankole.Plugins.Plugin do
  @moduledoc """
  Contract a first-party plugin module declares to the registry.

  A plugin declares its identity through `plugin_id/0`. It can contribute
  AppConfigure keys, subsystem adapters, domain transaction hooks, and
  supervised children. `activation/0` selects optional site activation or
  fixed activation with the source build. All callbacks except identity are
  optional. `Ankole.Plugins.Spec.from_module/1` validates these declarations
  and builds a `Spec`.
  """

  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition

  @type localized_text :: %{required(String.t()) => String.t()}
  @type adapter_declaration :: map()

  @callback plugin_id() :: String.t()
  @callback activation() :: :optional | :always
  @callback hooks() :: [{atom(), module()}]
  @callback display_name() :: localized_text() | nil
  @callback description() :: localized_text() | nil
  @callback app_config_definitions() :: [Definition.t()]
  @callback app_config_patterns() :: [PatternDefinition.t()]
  @callback adapter_declarations() :: [adapter_declaration()]
  @callback children() :: [Supervisor.child_spec()]

  @optional_callbacks activation: 0,
                      hooks: 0,
                      display_name: 0,
                      description: 0,
                      app_config_definitions: 0,
                      app_config_patterns: 0,
                      adapter_declarations: 0,
                      children: 0
end
