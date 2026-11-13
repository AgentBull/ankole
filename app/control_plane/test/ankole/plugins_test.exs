defmodule Ankole.PluginsTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry, as: AppConfigureRegistry
  alias Ankole.PluginFixtures.AlphaPlugin
  alias Ankole.PluginFixtures.BetaPlugin
  alias Ankole.PluginFixtures.DuplicateAdapterPlugin
  alias Ankole.PluginFixtures.DuplicateAlphaPlugin
  alias Ankole.PluginFixtures.MissingRemovedCallbackPlugin
  alias Ankole.PluginFixtures.MissingSignalsDeliveryReconcilePlugin
  alias Ankole.PluginFixtures.MissingSignalsDeliverySendPlugin
  alias Ankole.PluginFixtures.MissingIdentityCallbackPlugin
  alias Ankole.PluginFixtures.MissingAIGatewayEmbeddingPreparePlugin
  alias Ankole.PluginFixtures.UnknownSignalsOutboundCapabilityPlugin
  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Contracts
  alias Ankole.Plugins.Registry
  alias Ankole.Plugins.Spec
  alias Ankole.WebappExtension
  alias Mix.Tasks.Ankole.Webapps.Generate, as: WebappsGenerateTask

  import ExUnit.CaptureLog

  defmodule ValidWebappExtension do
    use Ankole.WebappExtension, id: "relay_ext"

    @impl true
    def generated_files(context) do
      [
        %{
          path: Path.join(context.internals_root, "webapps/modules/relay/generated.ts"),
          content: "export const relayGenerated = true"
        }
      ]
    end
  end

  defmodule SecondWebappExtension do
    use Ankole.WebappExtension, id: "billing_ext"

    @impl true
    def generated_files(context) do
      [
        %{
          path: Path.join(context.webapps_root, "common/billing.gen.ts"),
          content: "export const billingGenerated = true\n"
        }
      ]
    end
  end

  defmodule DuplicateIdWebappExtension do
    use Ankole.WebappExtension, id: "relay_ext"

    @impl true
    def generated_files(_context), do: []
  end

  defmodule UnsafePathWebappExtension do
    use Ankole.WebappExtension, id: "unsafe_ext"

    @impl true
    def generated_files(context) do
      [
        %{
          path: Path.join(context.repository_root, "outside.ts"),
          content: "export const unsafe = true\n"
        }
      ]
    end
  end

  defmodule DuplicatePathWebappExtension do
    use Ankole.WebappExtension, id: "duplicate_path_ext"

    @impl true
    def generated_files(context) do
      [
        %{
          path: Path.join(context.internals_root, "webapps/modules/relay/generated.ts"),
          content: "export const duplicate = true\n"
        }
      ]
    end
  end

  defmodule FailingValidateWebappExtension do
    use Ankole.WebappExtension, id: "failing_ext"

    @impl true
    def validate!, do: raise("broken contract")

    @impl true
    def generated_files(_context), do: []
  end

  defmodule WebappExtensionPlugin do
    @behaviour Ankole.Plugins.Plugin

    @impl true
    def plugin_id, do: "ext-plugin"

    @impl true
    def webapp_extensions, do: [ValidWebappExtension]
  end

  defmodule InvalidWebappExtensionPlugin do
    @behaviour Ankole.Plugins.Plugin

    @impl true
    def plugin_id, do: "invalid-ext-plugin"

    @impl true
    def webapp_extensions, do: [String]
  end

  setup do
    AppConfigureRegistry.clear_for_test()

    # A fixture Registry replaces the global AppConfigure plugin declarations.
    # Reset them after each test, so that later test modules find the live
    # plugin keys.
    on_exit(fn ->
      AppConfigureRegistry.clear_for_test()
    end)

    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

    :ok
  end

  test "starts no discovered plugins when the enable list is missing" do
    :ok = AppConfigure.delete_global(Config.enabled_ids_definition())

    registry = start_registry!()

    assert Enum.map(Registry.list_discovered(registry), & &1.id) == ["alpha", "beta"]
    assert Registry.list_active(registry) == []
    refute Registry.active?("alpha", registry)
    refute Registry.active?("beta", registry)
  end

  test "uses global enabled ids as a next-start activation policy" do
    assert {:ok, ["alpha"]} = Config.put_enabled_ids(["alpha"])

    registry = start_registry!()

    assert Enum.map(Registry.list_discovered(registry), & &1.id) == ["alpha", "beta"]
    assert Enum.map(Registry.list_active(registry), & &1.id) == ["alpha"]
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

    assert {:ok, false} =
             Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    registry = start_registry!()

    assert Enum.map(Registry.list_active(registry), & &1.id) == ["alpha", "beta"]
    assert Registry.active?("alpha", registry)
    assert Registry.active?("beta", registry)

    beta_definition = BetaPlugin.app_config_definitions() |> List.first()
    assert {:ok, false} = AppConfigure.put_global(beta_definition, false)

    assert Enum.map(Registry.adapter_declarations("test.adapter", registry), & &1.id) == [
             "alpha-adapter",
             "beta-adapter"
           ]

    assert {:ok, true} =
             Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

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

  test "active invalid known adapter contract declarations fail registry startup" do
    assert_contract_startup_failure(
      MissingRemovedCallbackPlugin,
      "signals.adapter",
      "missing-removed-callback",
      {:missing_adapter_callback, MissingRemovedCallbackPlugin, :handle_message_removed, 3}
    )

    assert_contract_startup_failure(
      UnknownSignalsOutboundCapabilityPlugin,
      "signals.adapter",
      "unknown-signals-outbound-capability",
      {:unknown_intent_capability, "made_up"}
    )

    assert_contract_startup_failure(
      MissingSignalsDeliverySendPlugin,
      "signals.adapter",
      "missing-signals-intent-send",
      {:missing_adapter_callback, MissingSignalsDeliverySendPlugin, :deliver, 1}
    )

    assert_contract_startup_failure(
      MissingSignalsDeliveryReconcilePlugin,
      "signals.adapter",
      "missing-signals-intent-reconcile",
      {:missing_adapter_callback, MissingSignalsDeliveryReconcilePlugin, :reconcile, 1}
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

  test "Connector declarations require the protocol entry points" do
    assert {:error, {:missing_connector_callbacks, String, [tools: 0, call: 3]}} =
             Contracts.validate("connectors.connector", %{module: String})

    assert {:error, {:invalid_connector_declaration, %{}}} =
             Contracts.validate("connectors.connector", %{})
  end

  test "Plugin.Spec validates webapp_extensions declarations" do
    assert {:ok, %Spec{webapp_extensions: [ValidWebappExtension]}} =
             Spec.from_module(WebappExtensionPlugin)

    assert {:error, {InvalidWebappExtensionPlugin, {:invalid_list_items, :webapp_extensions}}} =
             Spec.from_module(InvalidWebappExtensionPlugin)
  end

  test "WebappExtension discovers, validates, and expands safe TypeScript artifacts" do
    temp_root =
      Path.join(
        System.tmp_dir!(),
        "ankole_webapp_ext_#{System.unique_integer([:positive])}"
      )

    context = %{
      edition: "saas",
      repository_root: temp_root,
      webapps_root: Path.join(temp_root, "app/webapps"),
      internals_root: Path.join(temp_root, "internals")
    }

    on_exit(fn -> File.rm_rf!(temp_root) end)

    assert {:ok, [SecondWebappExtension, ValidWebappExtension]} =
             WebappExtension.discover([ValidWebappExtension, SecondWebappExtension])

    assert {:error,
            {:duplicate_extension_id, "relay_ext", DuplicateIdWebappExtension,
             ValidWebappExtension}} =
             WebappExtension.discover([ValidWebappExtension, DuplicateIdWebappExtension])

    assert {:error, {FailingValidateWebappExtension, {:validation_failed, "broken contract"}}} =
             WebappExtension.discover([FailingValidateWebappExtension])

    assert {:ok, [billing_file, relay_file]} =
             WebappExtension.generate_all(context, [ValidWebappExtension, SecondWebappExtension])

    assert billing_file.extension_id == "billing_ext"
    assert billing_file.content == "export const billingGenerated = true\n"
    assert relay_file.extension_id == "relay_ext"
    assert relay_file.content == "export const relayGenerated = true\n"

    assert {:error, {UnsafePathWebappExtension, {:unsafe_generated_path, _}}} =
             WebappExtension.generate_all(context, [UnsafePathWebappExtension])

    assert {:error,
            {:duplicate_generated_path, _, DuplicatePathWebappExtension, ValidWebappExtension}} =
             WebappExtension.generate_all(context, [
               ValidWebappExtension,
               DuplicatePathWebappExtension
             ])

    assert :ok = WebappsGenerateTask.run(["--check"])
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
