defmodule Ankole.PluginFixtures.InvalidAdapterModulePlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "invalid-adapter-module"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "principals.identity_provider",
        id: "missing-module",
        module: Ankole.PluginFixtures.MissingIdentityAdapter
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.MissingIdentityCallbackPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "missing-identity-callback"

  @impl true
  def api_version, do: 1

  @impl true
  def adapter_declarations do
    [
      %{
        contract_id: "principals.identity_provider",
        id: "missing-callback",
        module: __MODULE__
      }
    ]
  end
end

defmodule Ankole.PluginFixtures.DuplicateAdapterPlugin do
  @moduledoc false

  @behaviour Ankole.Plugins.Plugin

  @impl true
  def plugin_id, do: "duplicate-adapter"

  @impl true
  def api_version, do: 1

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
end
