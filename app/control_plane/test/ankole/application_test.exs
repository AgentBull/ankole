defmodule Ankole.ApplicationTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure.Declarations
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.I18n
  alias Ankole.Plugins.Registry, as: PluginRegistry

  test "loads CardKit translations before Delivery and Sessions can recover durable replies" do
    reverse_start_order =
      Ankole.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    delivery_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.Conversations.Delivery.Supervisor))

    i18n_catalog_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.I18n.Catalog))

    assert delivery_index < i18n_catalog_index

    for locale <- ["en-US", "zh-Hans-CN"] do
      translated = I18n.t("conversations.delivery.cardkit.refining", %{}, locale: locale)
      assert is_binary(translated) and translated != ""
      refute translated == "conversations.delivery.cardkit.refining"
    end
  end

  test "starts Delivery and Sessions before Workflow and Oban before plugin enqueue" do
    reverse_start_order =
      Ankole.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    delivery_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.Conversations.Delivery.Supervisor))

    workflow_index =
      Enum.find_index(reverse_start_order, &(&1 == Ankole.Workflow.Supervisor))

    assert workflow_index < delivery_index

    oban_index = Enum.find_index(reverse_start_order, &(&1 == Oban))
    plugins_index = Enum.find_index(reverse_start_order, &(&1 == Ankole.Plugins.Cohort))
    assert plugins_index < oban_index

    runtime_children =
      Ankole.AgentWorkers.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))

    assert Ankole.Sessions.Supervisor in reverse_start_order
    assert Ankole.AgentWorkers.Supervisor in reverse_start_order
    refute Ankole.Sessions.Supervisor in runtime_children
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

    actual_keys = MapSet.new(Ankole.AppConfigure.Registry.list_definitions(), & &1.key)
    actual_pattern_ids = MapSet.new(AppConfigureRegistry.list_patterns(), & &1.id)

    assert MapSet.subset?(expected_core_keys, actual_keys)
    assert MapSet.subset?(expected_plugin_keys, actual_keys)
    assert MapSet.subset?(expected_plugin_pattern_ids, actual_pattern_ids)
  end

  test "Plugin registry and snapshot consumers restart as one failure cohort" do
    old_registry = Process.whereis(PluginRegistry)
    old_supervisor = Process.whereis(Ankole.Plugins.Supervisor)
    active_ids = Enum.map(PluginRegistry.list_active(old_registry), & &1.id)
    child_ids = await_plugin_child_ids!(old_supervisor)

    new_registry = restart_named!(PluginRegistry)
    new_supervisor = await_new_named!(Ankole.Plugins.Supervisor, old_supervisor)
    new_child_ids = await_plugin_child_ids!(new_supervisor)

    assert new_registry != old_registry
    assert new_supervisor != old_supervisor
    assert Enum.map(PluginRegistry.list_active(new_registry), & &1.id) == active_ids
    assert new_child_ids == child_ids

    {plugin_definitions, plugin_patterns} =
      PluginRegistry.app_config_declarations(new_registry)

    actual_keys = MapSet.new(Ankole.AppConfigure.Registry.list_definitions(), & &1.key)
    actual_pattern_ids = MapSet.new(AppConfigureRegistry.list_patterns(), & &1.id)

    assert MapSet.subset?(MapSet.new(plugin_definitions, & &1.key), actual_keys)
    assert MapSet.subset?(MapSet.new(plugin_patterns, & &1.id), actual_pattern_ids)
  end

  test "long-connection owners terminate when their linked Registry partition exits" do
    for owner <- [
          Ankole.Plugins.WeComAdapter.ConnectionOwner
        ] do
      state = struct!(owner)
      assert {:stop, :killed, ^state} = owner.handle_info({:EXIT, self(), :killed}, state)
    end
  end

  test "temporary SDK clients terminate with their Registry partition" do
    registry = __MODULE__.SDKRegistry
    start_supervised!({Registry, keys: :unique, name: registry})
    test = self()

    req_options = [
      plug: fn _conn ->
        send(test, {:sdk_request, self()})

        receive do
          :unexpected_release -> flunk("Registry did not terminate the SDK client")
        end
      end
    ]

    clients = [
      {Ankole.Plugins.LarkAdapter.ConnectionReconciler, FeishuOpenAPI.WS.Client,
       FeishuOpenAPI.Client.new("cli_registry", "registry-secret", req_options: req_options),
       FeishuOpenAPI.Event.Dispatcher.new()},
      {Ankole.Plugins.SlackAdapter.ConnectionReconciler, SlackOpenAPI.SocketMode.Client,
       SlackOpenAPI.Client.new(app_token: "xapp-registry", req_options: req_options),
       SlackOpenAPI.SocketMode.Dispatcher.new()},
      {Ankole.Plugins.DingTalkAdapter.ConnectionReconciler, DingTalkOpenAPI.Stream.Client,
       DingTalkOpenAPI.Client.new(
         client_id: "registry-dingtalk",
         client_secret: "registry-secret",
         req_options: req_options
       ), DingTalkOpenAPI.Stream.Dispatcher.new()}
    ]

    running =
      Enum.map(clients, fn {reconciler, sdk, client, dispatcher} ->
        config =
          case sdk do
            FeishuOpenAPI.WS.Client ->
              %{"appID" => "cli_registry", "appSecret" => "registry-secret", "domain" => "feishu"}

            SlackOpenAPI.SocketMode.Client ->
              %{"appToken" => "xapp-registry", "botToken" => "xoxb-registry"}

            DingTalkOpenAPI.Stream.Client ->
              %{"clientId" => "registry-dingtalk", "clientSecret" => "registry-secret"}
          end

        consumers = [%{kind: :chat, tenant_id: Repo.tenant_id!(), config: config}]
        assert %{restart: :temporary} = reconciler.owner_child_spec(sdk, config, consumers)

        child = %{
          id: sdk,
          start:
            {sdk, :start_link,
             [[client: client, dispatcher: dispatcher, name: {:via, Registry, {registry, sdk}}]]},
          restart: :temporary
        }

        pid = start_supervised!(child)
        assert [{^pid, _}] = Registry.lookup(registry, sdk)
        assert_receive {:sdk_request, ^pid}, 2_000
        {pid, Process.monitor(pid)}
      end)

    [{_id, partition, _type, _modules}] = Supervisor.which_children(registry)
    Process.exit(partition, :kill)

    for {pid, ref} <- running do
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    end

    for {_reconciler, sdk, _client, _dispatcher} <- clients do
      assert Registry.lookup(registry, sdk) == []
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

  # A plugin child that starts during a test does start work with the shared
  # SQL Sandbox connection of the test: a reconciler makes one pass in
  # `handle_continue/2`, and a startup sync runs once as a `:temporary` task.
  # Wait for this work before the sandbox owner stops. Otherwise a reconciler
  # can crash, restart, and read the data of a later test. A `:temporary` child
  # leaves the child list when it stops, so the result contains only the
  # children that stay.
  defp await_plugin_child_ids!(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.flat_map(fn {id, pid, _type, _modules} ->
      case :supervisor.get_childspec(supervisor, id) do
        {:ok, %{restart: :temporary}} ->
          await_exit!(pid)
          []

        {:ok, _spec} ->
          :sys.get_state(pid)
          [id]

        {:error, :not_found} ->
          []
      end
    end)
    |> Enum.sort()
  end

  defp await_exit!(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end
end
