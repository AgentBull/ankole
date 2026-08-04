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
  alias Ankole.PluginFixtures.MissingSignalsOutboxReconcilePlugin
  alias Ankole.PluginFixtures.MissingSignalsOutboxSendPlugin
  alias Ankole.PluginFixtures.MissingDefaultLocalizedTextPlugin
  alias Ankole.PluginFixtures.MissingIdentityCallbackPlugin
  alias Ankole.PluginFixtures.MissingAIGatewayEmbeddingPreparePlugin
  alias Ankole.PluginFixtures.MissingAIGatewayProviderDefinitionPlugin
  alias Ankole.PluginFixtures.StringAdapterDisplayNamePlugin
  alias Ankole.PluginFixtures.StringLocalizedTextPlugin
  alias Ankole.PluginFixtures.UnknownIdentityCapabilityPlugin
  alias Ankole.PluginFixtures.UnknownSignalsInboundCapabilityPlugin
  alias Ankole.PluginFixtures.UnknownSignalsOutboundCapabilityPlugin
  alias Ankole.Plugins
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.Spec
  alias Ankole.Setup.Config, as: SetupConfig

  import ExUnit.CaptureLog

  setup do
    allow_cache_database_access()
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()
    :ok = SetupConfig.ensure_registered()
    {:ok, true} = SetupConfig.put_completed(true)

    :ok
  end

  test "starts no discovered plugins when the enable list is missing" do
    :ok = Config.ensure_registered()
    :ok = AppConfigure.delete_global(Config.enabled_ids_definition())

    registry = start_registry!()

    assert Enum.map(Registry.list_discovered(registry), & &1.id) == ["alpha", "beta"]
    assert Registry.list_active(registry) == []
    assert Registry.enabled_ids(registry) == []
    refute Registry.active?("alpha", registry)
    refute Registry.active?("beta", registry)
  end

  test "uses global enabled ids as a next-start activation policy" do
    assert {:ok, ["alpha"]} = Config.put_enabled_ids(["alpha"])

    registry = start_registry!()

    assert Enum.map(Registry.list_discovered(registry), & &1.id) == ["alpha", "beta"]
    assert Enum.map(Registry.list_active(registry), & &1.id) == ["alpha"]
    assert Registry.enabled_ids(registry) == ["alpha"]
    assert Registry.active?("alpha", registry)
    refute Registry.active?("beta", registry)

    assert {:ok, ["alpha", "beta"]} = Config.put_enabled_ids(["alpha", "beta"])
    refute Registry.active?("beta", registry)

    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()

    restarted_registry = start_registry!()
    assert Registry.active?("beta", restarted_registry)
  end

  test "unfinished setup activates every discovered plugin and preserves the next-start policy" do
    assert {:ok, ["alpha"]} = Config.put_enabled_ids(["alpha"])
    assert {:ok, false} = SetupConfig.put_completed(false)

    registry = start_registry!()

    assert Enum.map(Registry.list_active(registry), & &1.id) == ["alpha", "beta"]
    assert Registry.enabled_ids(registry) == ["alpha"]
    assert Registry.active?("alpha", registry)
    assert Registry.active?("beta", registry)

    beta_definition = BetaPlugin.app_config_definitions() |> List.first()
    assert {:ok, false} = AppConfigure.put_global(beta_definition, false)

    assert Enum.map(Registry.adapter_declarations("test.adapter", registry), & &1.id) == [
             "alpha-adapter",
             "beta-adapter"
           ]

    assert {:ok, true} = SetupConfig.put_completed(true)
    AppConfigureRegistry.clear_for_test()
    Cache.clear_for_test()

    restarted_registry = start_registry!()
    assert Enum.map(Registry.list_active(restarted_registry), & &1.id) == ["alpha"]
    refute Registry.active?("beta", restarted_registry)
  end

  test "plugins outside the enable list do not expose config definitions or adapters" do
    assert {:ok, ["alpha"]} = Config.put_enabled_ids(["alpha"])

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
             Registry.init(modules: [AlphaPlugin, DuplicateAlphaPlugin])

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
          MissingSignalsOutboxReconcilePlugin,
          MissingSignalsOutboxSendPlugin,
          UnknownSignalsInboundCapabilityPlugin,
          UnknownSignalsOutboundCapabilityPlugin,
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
      UnknownSignalsOutboundCapabilityPlugin,
      "signals_gateway.adapter",
      "unknown-signals-outbound-capability",
      {:unknown_outbox_capability, "made_up"}
    )

    assert_contract_startup_failure(
      MissingSignalsOutboxSendPlugin,
      "signals_gateway.adapter",
      "missing-signals-outbox-send",
      {:missing_adapter_callback, MissingSignalsOutboxSendPlugin, :send, 1}
    )

    assert_contract_startup_failure(
      MissingSignalsOutboxReconcilePlugin,
      "signals_gateway.adapter",
      "missing-signals-outbox-reconcile",
      {:missing_adapter_callback, MissingSignalsOutboxReconcilePlugin, :reconcile, 1}
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
    assert {:ok, ["alpha", "duplicate-adapter"]} =
             Config.put_enabled_ids(["alpha", "duplicate-adapter"])

    assert {:stop, {:duplicate_adapter_declaration, "test.adapter", "alpha-adapter", modules}} =
             Registry.init(modules: [AlphaPlugin, DuplicateAdapterPlugin])

    assert AlphaPlugin in modules
    assert DuplicateAdapterPlugin in modules
  end

  test "plugin supervisor starts children from active plugins only" do
    assert {:ok, ["alpha"]} = Config.put_enabled_ids(["alpha"])

    registry = start_registry!()

    supervisor =
      start_supervised!({Ankole.Plugins.Supervisor, registry: registry, name: supervisor_name()})

    assert [
             {Ankole.PluginFixtures.AlphaWorker, _pid, :worker,
              [Ankole.PluginFixtures.AlphaWorker]}
           ] =
             Supervisor.which_children(supervisor)
  end

  test "default registry validates the compile-time plugin list" do
    assert Enum.map(Plugins.list_discovered(), & &1.module) == [
             Ankole.Plugins.ChinaMarketAIProviders,
             Ankole.Plugins.DingTalkAdapter,
             Ankole.Plugins.GoogleWorkspaceAdapter,
             Ankole.Plugins.LarkAdapter,
             Ankole.Plugins.Microsoft365Adapter,
             Ankole.Plugins.SlackAdapter,
             Ankole.Plugins.WeComAdapter
           ]

    assert is_list(Plugins.list_active())
  end

  test "enable-list configuration is global-only and validates explicit future ids" do
    definition = Config.enabled_ids_definition()

    assert definition.scope == :global

    assert {:ok, ["alpha", "future-plugin"]} =
             Config.put_enabled_ids(["alpha", "future-plugin"])

    assert {:error, {:duplicate_plugin_id, "alpha"}} =
             Config.put_enabled_ids(["alpha", "alpha"])

    assert {:error, {:invalid_plugin_id, "Not-A-Plugin"}} =
             Config.put_enabled_ids(["Not-A-Plugin"])
  end

  defp start_registry! do
    name = registry_name()

    start_supervised!(%{
      id: name,
      start: {Registry, :start_link, [[name: name, modules: [AlphaPlugin, BetaPlugin]]]}
    })
  end

  defp registry_name do
    :"ankole_plugin_registry_#{System.unique_integer([:positive])}"
  end

  defp supervisor_name do
    :"ankole_plugin_supervisor_#{System.unique_integer([:positive])}"
  end

  defp assert_contract_startup_failure(module, contract_id, adapter_id, expected_reason) do
    assert {:ok, [_plugin_id]} = Config.put_enabled_ids([module.plugin_id()])

    log =
      capture_log(fn ->
        assert {:stop, reason} =
                 Registry.init(modules: [module])

        assert {:invalid_adapter_contract_declaration, ^contract_id, ^adapter_id, _plugin_id,
                ^module, ^expected_reason} = reason
      end)

    assert log =~ "Plugin registry startup failed"
    assert log =~ contract_id
    assert log =~ adapter_id
  end
end
