defmodule BullX.Plugins.SupervisorTest do
  use ExUnit.Case, async: false

  alias BullX.Plugins.{Discovery, Supervisor}

  test "starts children only for enabled plugins" do
    {:ok, plugin} =
      Discovery.discover_app(:test_child_plugin, modules: [BullX.Plugins.TestChildPlugin])

    assert {:ok, supervisor} =
             start_supervised(
               {Supervisor,
                plugins: [plugin],
                enabled_plugins: ["test_child_plugin"],
                name: :test_plugin_supervisor,
                registry_name: :test_plugin_registry}
             )

    assert is_pid(supervisor)
    assert is_pid(Process.whereis(BullX.Plugins.TestWorker))
  end

  test "rejects unknown enabled plugins before starting children" do
    {:ok, plugin} =
      Discovery.discover_app(:test_child_plugin, modules: [BullX.Plugins.TestChildPlugin])

    assert_raise RuntimeError, ~r/unknown_enabled_plugins/, fn ->
      start_supervised!(
        {Supervisor,
         plugins: [plugin],
         enabled_plugins: ["missing"],
         name: :test_plugin_supervisor_unknown,
         registry_name: :test_plugin_registry_unknown}
      )
    end
  end
end
