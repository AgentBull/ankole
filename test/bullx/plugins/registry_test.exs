defmodule BullX.Plugins.RegistryTest do
  use ExUnit.Case, async: true

  alias BullX.Plugins.{Discovery, Registry}

  setup do
    {:ok, test_plugin} = Discovery.discover_app(:test_plugin, modules: [BullX.Plugins.TestPlugin])

    {:ok, other_plugin} =
      Discovery.discover_app(:test_other_plugin, modules: [BullX.Plugins.TestOtherPlugin])

    %{test_plugin: test_plugin, other_plugin: other_plugin}
  end

  test "builds registry state and filters enabled extensions", %{test_plugin: test_plugin} do
    assert {:ok, state} = Registry.build([test_plugin], ["test_plugin"])

    assert Enum.map(state.plugins, & &1.id) == ["test_plugin"]
    assert MapSet.equal?(state.enabled_ids, MapSet.new(["test_plugin"]))
    assert [%BullX.Plugins.Extension{plugin_id: "test_plugin"}] = enabled_extensions(state)
  end

  test "rejects unknown enabled plugin ids", %{test_plugin: test_plugin} do
    assert {:error, {:unknown_enabled_plugins, ["missing"]}} =
             Registry.build([test_plugin], ["missing"])
  end

  test "rejects duplicate extension ids", %{test_plugin: test_plugin, other_plugin: other_plugin} do
    assert {:error, {:duplicate_plugin_extensions, [test_point: :primary]}} =
             Registry.build([test_plugin, other_plugin], [])
  end

  defp enabled_extensions(%Registry{} = state) do
    Enum.filter(state.extensions, fn extension ->
      extension.point == :test_point and MapSet.member?(state.enabled_ids, extension.plugin_id)
    end)
  end
end
