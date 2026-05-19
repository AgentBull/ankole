defmodule BullX.AIAgent.Tools.Registry do
  @moduledoc """
  Code-owned AIAgent ToolSet registry.

  V1 ships only a fake search tool so the Agentic Loop can validate registry,
  ACL filtering, idempotency, timeout, and tool-result persistence without
  shipping real external tool effects.
  """

  @fake_search %{
    name: "web_search",
    toolset_id: "web_research",
    description: "Fake search tool used by AIAgent loop tests.",
    parameter_schema: [
      query: [type: :string, required: true, doc: "Search query"]
    ],
    default_access: :ordinary,
    timeout_ms: 30_000,
    parallel_safe: true,
    module: BullX.AIAgent.Tools.FakeSearch
  }

  @toolsets %{
    "web_research" => %{
      id: "web_research",
      default_access: :ordinary,
      description: "Fake web research ToolSet for AIAgent loop tests."
    }
  }

  @tools %{"web_search" => @fake_search}

  @spec list_toolsets() :: [map()]
  def list_toolsets, do: Map.values(@toolsets)

  @spec list_tools() :: [map()]
  def list_tools, do: Map.values(@tools)

  @spec get_tool(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_tool(tool_name) when is_binary(tool_name) do
    case Map.fetch(@tools, tool_name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, :not_found}
    end
  end

  @spec tools_for_toolset(String.t()) :: [map()]
  def tools_for_toolset(toolset_id) when is_binary(toolset_id) do
    @tools
    |> Map.values()
    |> Enum.filter(&(&1.toolset_id == toolset_id))
  end

  @spec toolset(String.t()) :: {:ok, map()} | {:error, :not_found}
  def toolset(toolset_id) when is_binary(toolset_id) do
    case Map.fetch(@toolsets, toolset_id) do
      {:ok, toolset} -> {:ok, toolset}
      :error -> {:error, :not_found}
    end
  end
end
