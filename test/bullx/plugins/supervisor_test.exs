defmodule BullX.Plugins.SupervisorTest do
  use ExUnit.Case, async: false

  alias BullX.Plugins.{Discovery, Supervisor}

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
