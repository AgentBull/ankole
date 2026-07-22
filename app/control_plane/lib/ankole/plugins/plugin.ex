defmodule Ankole.Plugins.Plugin do
  @moduledoc """
  Contract a first-party plugin module declares to the registry.

  A plugin advertises an identity through `plugin_id/0` and may contribute
  AppConfigure keys, adapter declarations
  (the data that lets a plugin plug into a subsystem contract such as
  `signals_gateway.adapter` or `principals.identity_provider`), and supervised
  children. Everything except identity is optional, so a minimal plugin only
  implements `plugin_id/0`. `Ankole.Plugins.Spec.from_module/1`
  reads these callbacks and normalizes the result into a `Spec`.
  """

  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition

  @type localized_text :: %{required(String.t()) => String.t()}
  @type adapter_declaration :: map()

  @callback plugin_id() :: String.t()
  @callback display_name() :: localized_text() | nil
  @callback description() :: localized_text() | nil
  @callback app_config_definitions() :: [Definition.t()]
  @callback app_config_patterns() :: [PatternDefinition.t()]
  @callback adapter_declarations() :: [adapter_declaration()]
  @callback children() :: [Supervisor.child_spec()]

  @optional_callbacks display_name: 0,
                      description: 0,
                      app_config_definitions: 0,
                      app_config_patterns: 0,
                      adapter_declarations: 0,
                      children: 0
end
