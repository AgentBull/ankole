defmodule BullX.Plugins.TestExtensionModule do
  @moduledoc false
end

defmodule BullX.Plugins.TestPlugin do
  use BullX.Plugins.Plugin, app: :test_plugin

  @impl true
  def extensions do
    [
      %{
        point: :test_point,
        id: :primary,
        module: BullX.Plugins.TestExtensionModule,
        opts: [mode: :test]
      }
    ]
  end

  @impl true
  def config_modules do
    [BullX.Plugins.TestConfig]
  end
end

defmodule BullX.Plugins.TestOtherPlugin do
  use BullX.Plugins.Plugin, app: :test_other_plugin

  @impl true
  def extensions do
    [
      %{
        point: :test_point,
        id: :primary,
        module: BullX.Plugins.TestExtensionModule
      }
    ]
  end
end

defmodule BullX.Plugins.TestSecondEntry do
  use BullX.Plugins.Plugin, app: :duplicate_plugin
end

defmodule BullX.Plugins.TestThirdEntry do
  use BullX.Plugins.Plugin, app: :duplicate_plugin
end

defmodule BullX.Plugins.TestUnsupportedPlugin do
  use BullX.Plugins.Plugin, app: :unsupported_plugin, api_version: 999
end

defmodule BullX.Plugins.TestBadIdPlugin do
  use BullX.Plugins.Plugin, app: :bad_id_plugin, id: "wrong"
end

defmodule BullX.Plugins.TestWorker do
  use GenServer

  def start_link(context) do
    GenServer.start_link(__MODULE__, context, name: __MODULE__)
  end

  @impl true
  def init(context) do
    {:ok, context}
  end
end

defmodule BullX.Plugins.TestChildPlugin do
  use BullX.Plugins.Plugin, app: :test_child_plugin

  @impl true
  def children(context) do
    [{BullX.Plugins.TestWorker, context}]
  end
end
