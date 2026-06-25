defmodule Ankole.Plugins.Plugin do
  @moduledoc """
  Contract a first-party plugin module declares to the registry.

  A plugin advertises an identity (`plugin_id/0`, `api_version/0`) and may
  contribute any of: AppConfigure keys, setup wizard steps, adapter declarations
  (the data that lets a plugin plug into a subsystem contract such as
  `signals_gateway.adapter` or `principals.identity_provider`), and supervised
  children. Everything except identity is optional, so a minimal plugin only
  implements the two required callbacks. `Ankole.Plugins.Spec.from_module/1`
  reads these callbacks and normalizes the result into a `Spec`.
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
