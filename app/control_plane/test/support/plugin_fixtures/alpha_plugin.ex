defmodule Ankole.PluginFixtures.AlphaWorker do
  @moduledoc false

  use Agent

  def start_link(opts) do
    Agent.start_link(fn -> Keyword.get(opts, :value, :alpha) end)
  end
end

defmodule Ankole.PluginFixtures.AlphaPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema

  @impl true
  def plugin_id, do: "alpha"

  @impl true
  def api_version, do: 1

  @impl true
  def display_name, do: %{"en-US" => "Alpha"}

  @impl true
  def app_config_definitions do
    [
      AppConfigure.define(
        key: "test.plugins.alpha.enabled",
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
        id: "alpha-adapter",
        module: __MODULE__
      }
    ]
  end

  @impl true
  def children do
    [
      {Ankole.PluginFixtures.AlphaWorker, value: :alpha}
    ]
  end
end
