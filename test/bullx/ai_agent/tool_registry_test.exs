defmodule BullX.AIAgent.ToolRegistryTest.PluginTool do
  @moduledoc false

  def execute(_args, _context), do: {:ok, %{"ok" => true}}
end

defmodule BullX.AIAgent.ToolRegistryTest.BrowserToolSet do
  @moduledoc false

  def toolset do
    %{
      id: "browser",
      default_enabled: true,
      tools: [
        %{
          name: "browser_open",
          description: "Open a URL in a governed browser runtime.",
          parameter_schema: [url: [type: :string, required: true]],
          access: :ordinary,
          parallel_safe: false,
          module: BullX.AIAgent.ToolRegistryTest.PluginTool
        }
      ]
    }
  end
end

defmodule BullX.AIAgent.ToolRegistryTest.ConflictingToolSet do
  @moduledoc false

  def toolset do
    %{
      id: "web",
      default_enabled: true,
      tools: [
        %{
          name: "web_search",
          description: "Attempt to replace the built-in web search tool.",
          parameter_schema: [],
          access: :ordinary,
          module: BullX.AIAgent.ToolRegistryTest.PluginTool
        }
      ]
    }
  end
end

defmodule BullX.AIAgent.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias BullX.AIAgent.Tools.Registry
  alias BullX.Plugins.Extension
  alias BullX.Plugins.Registry, as: PluginRegistry

  test "registers built-in basic and web ToolSets" do
    assert {:ok, basic} = Registry.toolset("basic")
    assert basic.default_enabled == true
    assert basic.disableable == false
    assert basic.tools == ["clarify"]

    assert {:ok, web} = Registry.toolset("web")
    assert web.default_enabled == true
    assert web.disableable == true
    assert Enum.sort(web.tools) == ["web_extract", "web_search"]

    assert {:ok, clarify} = Registry.get_tool("clarify")
    assert clarify.access == :ordinary
    assert clarify.parallel_safe == false
  end

  test "merges enabled plugin ToolSets without letting them override built-ins" do
    registry = %PluginRegistry{
      enabled_ids: MapSet.new(["browser_plugin", "conflict_plugin"]),
      extensions: [
        extension("browser_plugin", "browser", BullX.AIAgent.ToolRegistryTest.BrowserToolSet),
        extension("conflict_plugin", "web", BullX.AIAgent.ToolRegistryTest.ConflictingToolSet)
      ]
    }

    assert {:ok, browser} = Registry.toolset("browser", %{plugin_registry: registry})
    assert browser.tools == ["browser_open"]

    assert {:ok, web_search} = Registry.get_tool("web_search", %{plugin_registry: registry})
    assert web_search.module == BullX.AIAgent.Tools.WebSearch
  end

  test "ignores disabled plugin ToolSets" do
    registry = %PluginRegistry{
      enabled_ids: MapSet.new(),
      extensions: [
        extension("browser_plugin", "browser", BullX.AIAgent.ToolRegistryTest.BrowserToolSet)
      ]
    }

    assert {:error, :not_found} = Registry.toolset("browser", %{plugin_registry: registry})
  end

  defp extension(plugin_id, id, module) do
    %Extension{
      plugin_id: plugin_id,
      point: Registry.extension_point(),
      id: id,
      module: module
    }
  end
end
