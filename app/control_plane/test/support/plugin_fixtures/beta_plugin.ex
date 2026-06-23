defmodule Ankole.PluginFixtures.BetaPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema

  @impl true
  def plugin_id, do: "beta"

  @impl true
  def api_version, do: 1

  @impl true
  def app_config_definitions do
    [
      AppConfigure.define(
        key: "test.plugins.beta.enabled",
        encrypted: false,
        schema: Schema.boolean(),
        default_value: true
      )
    ]
  end

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "test.adapter",
        id: "beta-adapter",
        module: __MODULE__
      }
    ]
  end
end
