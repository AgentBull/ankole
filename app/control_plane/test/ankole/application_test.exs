defmodule Ankole.ApplicationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Declarations
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.I18n
  alias Ankole.Plugins.Registry, as: PluginRegistry

  test "loads CardKit translations before SignalsGateway can recover durable replies" do
    reverse_start_order =
      Ankole.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    signals_gateway_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.SignalsGateway.Supervisor))

    i18n_catalog_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.I18n.Catalog))

    assert signals_gateway_index < i18n_catalog_index

    assert {:ok, "Refining the answer…"} =
             I18n.translate("signals_gateway.cardkit.refining", %{}, locale: "en-US")

    assert {:ok, "正在深思熟虑…"} =
             I18n.translate("signals_gateway.cardkit.refining", %{}, locale: "zh-Hans-CN")
  end

  test "starts Workflow after SignalsGateway and before RuntimeEvents" do
    reverse_start_order =
      Ankole.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    signals_gateway_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.SignalsGateway.Supervisor))

    workflow_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.Workflow.Supervisor))

    assert workflow_index < signals_gateway_index

    case Enum.find_index(reverse_start_order, &(&1 == Ankole.RuntimeEvents.Supervisor)) do
      nil ->
        refute Keyword.get(Application.get_env(:ankole, :runtime_events, []), :enabled, true)

      runtime_events_index ->
        assert runtime_events_index < workflow_index
    end
  end

  test "AppConfigure registry rebuilds core and active Plugin declarations without restarting consumers" do
    app_config_registry = restart_named!(AppConfigureRegistry)
    plugin_registry = Process.whereis(PluginRegistry)
    plugin_supervisor = Process.whereis(Ankole.Plugins.Supervisor)

    expected_core_keys = MapSet.new(Declarations.core_definitions(), & &1.key)

    {plugin_definitions, plugin_patterns} =
      PluginRegistry.app_config_declarations(plugin_registry)

    expected_plugin_keys = MapSet.new(plugin_definitions, & &1.key)
    expected_plugin_pattern_ids = MapSet.new(plugin_patterns, & &1.id)

    new_app_config_registry = restart_named!(AppConfigureRegistry)

    assert new_app_config_registry != app_config_registry
    assert Process.whereis(PluginRegistry) == plugin_registry
    assert Process.whereis(Ankole.Plugins.Supervisor) == plugin_supervisor

    actual_keys = MapSet.new(AppConfigure.list_definitions(), & &1.key)
    actual_pattern_ids = MapSet.new(AppConfigureRegistry.list_patterns(), & &1.id)

    assert MapSet.subset?(expected_core_keys, actual_keys)
    assert MapSet.subset?(expected_plugin_keys, actual_keys)
    assert MapSet.subset?(expected_plugin_pattern_ids, actual_pattern_ids)
  end

  test "Plugin registry and snapshot consumers restart as one failure cohort" do
    old_registry = Process.whereis(PluginRegistry)
    old_supervisor = Process.whereis(Ankole.Plugins.Supervisor)
    active_ids = Enum.map(PluginRegistry.list_active(old_registry), & &1.id)
    child_ids = plugin_child_ids(old_supervisor)

    new_registry = restart_named!(PluginRegistry)
    new_supervisor = await_new_named!(Ankole.Plugins.Supervisor, old_supervisor)

    assert new_registry != old_registry
    assert new_supervisor != old_supervisor
    assert Enum.map(PluginRegistry.list_active(new_registry), & &1.id) == active_ids
    assert plugin_child_ids(new_supervisor) == child_ids

    {plugin_definitions, plugin_patterns} =
      PluginRegistry.app_config_declarations(new_registry)

    actual_keys = MapSet.new(AppConfigure.list_definitions(), & &1.key)
    actual_pattern_ids = MapSet.new(AppConfigureRegistry.list_patterns(), & &1.id)

    assert MapSet.subset?(MapSet.new(plugin_definitions, & &1.key), actual_keys)
    assert MapSet.subset?(MapSet.new(plugin_patterns, & &1.id), actual_pattern_ids)
  end

  test "long-connection owners terminate when their linked Registry partition exits" do
    for owner <- [
          Ankole.Plugins.LarkAdapter.ConnectionOwner,
          Ankole.Plugins.SlackAdapter.ConnectionOwner,
          Ankole.Plugins.DingTalkAdapter.ConnectionOwner,
          Ankole.Plugins.WeComAdapter.ConnectionOwner
        ] do
      state = struct!(owner)
      assert {:stop, :killed, ^state} = owner.handle_info({:EXIT, self(), :killed}, state)
    end
  end

  defp restart_named!(name) do
    old_pid = Process.whereis(name)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}, 5_000
    await_new_named!(name, old_pid)
  end

  defp await_new_named!(name, old_pid, attempts \\ 500)

  defp await_new_named!(_name, _old_pid, 0), do: flunk("supervised process did not restart")

  defp await_new_named!(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _pid ->
        Process.sleep(10)
        await_new_named!(name, old_pid, attempts - 1)
    end
  end

  defp plugin_child_ids(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
