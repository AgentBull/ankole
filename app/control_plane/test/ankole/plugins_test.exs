defmodule Ankole.PluginsTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.PluginFixtures.AlphaPlugin
  alias Ankole.PluginFixtures.BetaPlugin
  alias Ankole.PluginFixtures.DuplicateAdapterPlugin
  alias Ankole.PluginFixtures.DuplicateAlphaPlugin
  alias Ankole.PluginFixtures.InvalidAdapterModulePlugin
  alias Ankole.PluginFixtures.MissingIdentityCallbackPlugin
  alias Ankole.Plugins
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Discovery
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.Spec

  setup do
    allow_cache_database_access()
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()

    :ok
  end

  test "discovers compiled plugin modules from source roots" do
    assert {:ok, specs} = Discovery.discover(roots: [fixture_root()])
    assert Enum.map(specs, & &1.id) == ["alpha", "beta"]
  end

  test "missing plugin roots are ignored" do
    missing_root =
      Path.join(System.tmp_dir!(), "ankole-missing-plugins-#{System.unique_integer([:positive])}")

    assert {:ok, []} = Discovery.discover(roots: [missing_root])
  end

  test "starts every discovered plugin unless disabled" do
    registry = start_registry!()

    assert Enum.map(Registry.list_discovered(registry), & &1.id) == ["alpha", "beta"]
    assert Enum.map(Registry.list_active(registry), & &1.id) == ["alpha", "beta"]
    assert Registry.active?("alpha", registry)
    assert Registry.active?("beta", registry)
  end

  test "uses global disabled ids as a next-start activation policy" do
    assert {:ok, ["beta"]} = Config.put_disabled_ids(["beta"])

    registry = start_registry!()

    assert Enum.map(Registry.list_discovered(registry), & &1.id) == ["alpha", "beta"]
    assert Enum.map(Registry.list_active(registry), & &1.id) == ["alpha"]
    assert Registry.disabled_ids(registry) == ["beta"]
    assert Registry.active?("alpha", registry)
    refute Registry.active?("beta", registry)

    assert {:ok, []} = Config.put_disabled_ids([])
    refute Registry.active?("beta", registry)

    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()

    restarted_registry = start_registry!()
    assert Registry.active?("beta", restarted_registry)
  end

  test "disabled plugins do not expose config definitions or adapters" do
    assert {:ok, ["beta"]} = Config.put_disabled_ids(["beta"])

    registry = start_registry!()

    alpha_definition = AlphaPlugin.app_config_definitions() |> List.first()
    beta_definition = BetaPlugin.app_config_definitions() |> List.first()

    assert {:ok, false} = AppConfigure.put_global(alpha_definition, false)

    assert {:error, {:unknown_key, "test.plugins.beta.enabled"}} =
             AppConfigure.put_global(beta_definition, false)

    assert [%{id: "alpha-adapter"}] = Registry.adapter_declarations("test.adapter", registry)
  end

  test "duplicate plugin ids fail registry startup" do
    assert {:stop, {:duplicate_plugin_id, "alpha", modules}} =
             Registry.init(
               discovery: [
                 roots: [],
                 modules: [AlphaPlugin, DuplicateAlphaPlugin]
               ]
             )

    assert AlphaPlugin in modules
    assert DuplicateAlphaPlugin in modules
  end

  test "invalid adapter declarations fail spec normalization" do
    assert {:error,
            {InvalidAdapterModulePlugin,
             {:invalid_adapter_declaration,
              {:adapter_module_not_loaded, :module, Ankole.PluginFixtures.MissingIdentityAdapter,
               _reason}}}} =
             Spec.from_module(InvalidAdapterModulePlugin)

    assert {:error,
            {MissingIdentityCallbackPlugin,
             {:invalid_adapter_declaration,
              {:missing_adapter_callback, MissingIdentityCallbackPlugin, :upsert_user, 2}}}} =
             Spec.from_module(MissingIdentityCallbackPlugin)
  end

  test "duplicate adapter declarations fail registry startup" do
    assert {:stop, {:duplicate_adapter_declaration, "test.adapter", "alpha-adapter", modules}} =
             Registry.init(
               discovery: [
                 roots: [],
                 modules: [AlphaPlugin, DuplicateAdapterPlugin]
               ]
             )

    assert AlphaPlugin in modules
    assert DuplicateAdapterPlugin in modules
  end

  test "plugin supervisor starts children from active plugins only" do
    assert {:ok, ["beta"]} = Config.put_disabled_ids(["beta"])

    registry = start_registry!()

    supervisor =
      start_supervised!({Ankole.Plugins.Supervisor, registry: registry, name: supervisor_name()})

    assert [
             {Ankole.PluginFixtures.AlphaWorker, _pid, :worker,
              [Ankole.PluginFixtures.AlphaWorker]}
           ] =
             Supervisor.which_children(supervisor)
  end

  test "facade exposes the default registry" do
    assert is_list(Plugins.list_discovered())
    assert is_list(Plugins.list_active())
  end

  defp start_registry! do
    name = registry_name()

    start_supervised!(%{
      id: name,
      start: {Registry, :start_link, [[name: name, discovery: [roots: [fixture_root()]]]]}
    })
  end

  defp fixture_root do
    Path.expand("../support/plugin_fixtures", __DIR__)
  end

  defp registry_name do
    :"ankole_plugin_registry_#{System.unique_integer([:positive])}"
  end

  defp supervisor_name do
    :"ankole_plugin_supervisor_#{System.unique_integer([:positive])}"
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
