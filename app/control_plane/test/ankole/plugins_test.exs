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
  alias Ankole.PluginFixtures.KebabAIGatewayProviderKindPlugin
  alias Ankole.PluginFixtures.MissingRemovedCallbackPlugin
  alias Ankole.PluginFixtures.MissingDefaultLocalizedTextPlugin
  alias Ankole.PluginFixtures.MissingIdentityCallbackPlugin
  alias Ankole.PluginFixtures.MissingAIGatewayEmbeddingPreparePlugin
  alias Ankole.PluginFixtures.MissingAIGatewayProviderDefinitionPlugin
  alias Ankole.PluginFixtures.StringAdapterDisplayNamePlugin
  alias Ankole.PluginFixtures.StringLocalizedTextPlugin
  alias Ankole.PluginFixtures.UnknownIdentityCapabilityPlugin
  alias Ankole.PluginFixtures.UnknownSignalsInboundCapabilityPlugin
  alias Ankole.Plugins
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Discovery
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.Spec

  import ExUnit.CaptureLog

  setup do
    allow_cache_database_access()
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()

    :ok
  end

  test "discovers compiled plugin modules from source paths" do
    assert {:ok, specs} = Discovery.discover(paths: [fixture_path()])
    assert Enum.map(specs, & &1.id) == ["alpha", "beta"]
  end

  test "uses configured plugin source paths as the default discovery paths" do
    previous_config = Application.get_env(:ankole, Discovery)
    fixture_path = fixture_path()

    Application.put_env(:ankole, Discovery, paths: [fixture_path])

    on_exit(fn ->
      case previous_config do
        nil -> Application.delete_env(:ankole, Discovery)
        config -> Application.put_env(:ankole, Discovery, config)
      end
    end)

    assert Discovery.default_paths() == [Path.expand(fixture_path)]
    assert {:ok, specs} = Discovery.discover()
    assert Enum.map(specs, & &1.id) == ["alpha", "beta"]
  end

  test "missing plugin paths are ignored" do
    missing_path =
      Path.join(System.tmp_dir!(), "ankole-missing-plugins-#{System.unique_integer([:positive])}")

    assert {:ok, []} = Discovery.discover(paths: [missing_path])
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
                 paths: [],
                 modules: [AlphaPlugin, DuplicateAlphaPlugin]
               ]
             )

    assert AlphaPlugin in modules
    assert DuplicateAlphaPlugin in modules
  end

  test "adapter declarations only validate plugin-owned generic shape" do
    assert {:error,
            {InvalidAdapterModulePlugin,
             {:invalid_adapter_declaration,
              {:adapter_module_not_loaded, :module, Ankole.PluginFixtures.MissingIdentityAdapter,
               _reason}}}} =
             Spec.from_module(InvalidAdapterModulePlugin)

    for module <- [
          MissingIdentityCallbackPlugin,
          MissingRemovedCallbackPlugin,
          UnknownSignalsInboundCapabilityPlugin,
          UnknownIdentityCapabilityPlugin,
          MissingAIGatewayProviderDefinitionPlugin,
          MissingAIGatewayEmbeddingPreparePlugin,
          KebabAIGatewayProviderKindPlugin
        ] do
      assert {:ok, %Spec{}} = Spec.from_module(module)
    end
  end

  test "active invalid known adapter contract declarations fail registry startup" do
    assert_contract_startup_failure(
      MissingRemovedCallbackPlugin,
      "signals_gateway.adapter",
      "missing-removed-callback",
      {:missing_adapter_callback, MissingRemovedCallbackPlugin, :handle_message_removed, 3}
    )

    assert_contract_startup_failure(
      MissingIdentityCallbackPlugin,
      "principals.identity_provider",
      "missing-callback",
      {:unsupported_identity_provider_operation, MissingIdentityCallbackPlugin, :upsert_user, 2}
    )

    assert_contract_startup_failure(
      MissingAIGatewayEmbeddingPreparePlugin,
      "ai_gateway.provider",
      "missing_embedding_prepare",
      {:missing_provider_callback, MissingAIGatewayEmbeddingPreparePlugin,
       :prepare_embedding_model, 1}
    )
  end

  test "plugin localized text must be an open locale map with a default fallback" do
    assert {:error,
            {StringLocalizedTextPlugin,
             {:invalid_localized_text, :display_name, "String Display Name"}}} =
             Spec.from_module(StringLocalizedTextPlugin)

    assert {:error,
            {MissingDefaultLocalizedTextPlugin,
             {:invalid_localized_text, :display_name, %{"en-US" => "Missing Default"}}}} =
             Spec.from_module(MissingDefaultLocalizedTextPlugin)

    assert {:error,
            {StringAdapterDisplayNamePlugin,
             {:invalid_adapter_declaration,
              {:invalid_adapter_localized_text, :display_name, "String Display Name"}}}} =
             Spec.from_module(StringAdapterDisplayNamePlugin)
  end

  test "duplicate adapter declarations fail registry startup" do
    assert {:stop, {:duplicate_adapter_declaration, "test.adapter", "alpha-adapter", modules}} =
             Registry.init(
               discovery: [
                 paths: [],
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
      start: {Registry, :start_link, [[name: name, discovery: [paths: [fixture_path()]]]]}
    })
  end

  defp fixture_path do
    Path.expand("../support/plugin_fixtures", __DIR__)
  end

  defp registry_name do
    :"ankole_plugin_registry_#{System.unique_integer([:positive])}"
  end

  defp supervisor_name do
    :"ankole_plugin_supervisor_#{System.unique_integer([:positive])}"
  end

  defp assert_contract_startup_failure(module, contract_id, adapter_id, expected_reason) do
    log =
      capture_log(fn ->
        assert {:stop, reason} =
                 Registry.init(
                   discovery: [
                     paths: [],
                     modules: [module]
                   ]
                 )

        assert {:invalid_adapter_contract_declaration, ^contract_id, ^adapter_id, _plugin_id,
                ^module, ^expected_reason} = reason
      end)

    assert log =~ "Plugin registry startup failed"
    assert log =~ contract_id
    assert log =~ adapter_id
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
