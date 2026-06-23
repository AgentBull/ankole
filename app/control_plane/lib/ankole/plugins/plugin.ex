defmodule Ankole.Plugins.Plugin do
  @moduledoc """
  Behaviour implemented by first-party Ankole plugin modules.
  """

  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition

  @type localized_text :: String.t() | %{String.t() => String.t()}
  @type adapter_declaration :: map()
  @type setup_metadata :: map()

  @callback plugin_id() :: String.t()
  @callback api_version() :: pos_integer()
  @callback display_name() :: localized_text() | nil
  @callback description() :: localized_text() | nil
  @callback app_config_definitions() :: [Definition.t()]
  @callback app_config_patterns() :: [PatternDefinition.t()]
  @callback setup_metadata() :: [setup_metadata()]
  @callback adapter_declarations() :: [adapter_declaration()]
  @callback children() :: [Supervisor.child_spec()]

  @optional_callbacks display_name: 0,
                      description: 0,
                      app_config_definitions: 0,
                      app_config_patterns: 0,
                      setup_metadata: 0,
                      adapter_declarations: 0,
                      children: 0
end
