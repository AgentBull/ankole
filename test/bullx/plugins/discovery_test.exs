defmodule BullX.Plugins.DiscoveryTest do
  use ExUnit.Case, async: true

  alias BullX.Plugins.Discovery

  test "discovers the single plugin entry module for an app" do
    assert {:ok, spec} =
             Discovery.discover_app(:test_plugin, modules: [BullX.Plugins.TestPlugin])

    assert spec.app == :test_plugin
    assert spec.id == "test_plugin"
    assert spec.module == BullX.Plugins.TestPlugin
    assert spec.api_version == 1
    assert spec.metadata.display_name == %{"en-US" => "Test plugin", "zh-Hans-CN" => "测试插件"}
    assert spec.metadata.description == "A test plugin."
    assert spec.config_modules == [BullX.Plugins.TestConfig]
    assert [%BullX.Plugins.Extension{point: :test_point, id: :primary}] = spec.extensions
  end

  test "plugin macro infers app id from plugins path" do
    [{module, _bytecode}] =
      Code.compile_string(
        """
        defmodule BullX.Plugins.InferredPathPlugin do
          use BullX.Plugins.Plugin
        end
        """,
        "plugins/inferred_path/lib/inferred_path_plugin.ex"
      )

    assert module.__bullx_plugin__().id == "inferred_path"
  end

  test "plugin macro infers app id from internals plugins path" do
    [{module, _bytecode}] =
      Code.compile_string(
        """
        defmodule BullX.Plugins.InferredInternalPathPlugin do
          use BullX.Plugins.Plugin
        end
        """,
        "internals/plugins/internal_path/lib/internal_path_plugin.ex"
      )

    assert module.__bullx_plugin__().id == "internal_path"
  end

  test "fails when no module exports the plugin marker" do
    assert {:error, {:plugin_entry_not_found, :test_plugin}} =
             Discovery.discover_app(:test_plugin, modules: [BullX.Plugins.TestExtensionModule])
  end

  test "fails when multiple modules export the plugin marker" do
    assert {:error, {:multiple_plugin_entries, :duplicate_plugin, modules}} =
             Discovery.discover_app(:duplicate_plugin,
               modules: [BullX.Plugins.TestSecondEntry, BullX.Plugins.TestThirdEntry]
             )

    assert modules == [BullX.Plugins.TestSecondEntry, BullX.Plugins.TestThirdEntry]
  end

  test "fails on unsupported plugin API versions" do
    assert {:error, {:unsupported_plugin_api_version, 999, 1}} =
             Discovery.discover_app(:unsupported_plugin,
               modules: [BullX.Plugins.TestUnsupportedPlugin]
             )
  end

  test "fails when plugin id does not match the app id" do
    assert {:error, {:plugin_id_mismatch, :bad_id_plugin, "wrong", "bad_id_plugin"}} =
             Discovery.discover_app(:bad_id_plugin, modules: [BullX.Plugins.TestBadIdPlugin])
  end

  test "fails when optional localized metadata fields are invalid" do
    assert {:error, {:invalid_plugin_metadata_field, :display_name, %{"en-US" => :bad}}} =
             Discovery.discover_app(:invalid_metadata_plugin,
               modules: [BullX.Plugins.TestInvalidMetadataPlugin]
             )
  end
end
