defmodule Ankole.AIGateway.CodexCodeMode do
  @moduledoc """
  Restores plain tool documentation under Codex code mode.

  Code mode gives Codex one `exec` tool that runs JavaScript over the other
  tools. It also appends one TypeScript `declare const tools` block to every
  other tool description (`augment_tool_definition`, codex rust-v0.147.0). Each
  block documents one tool, so every direct tool ends with instructions for the
  indirect path, and models wrap one call in a JavaScript program instead of
  calling the tool.

  AIGateway removes the appended block and keeps `exec` declared. One call then
  uses the direct tool, and `exec` keeps the case it exists for: more than one
  call. Codex has no configuration that separates the appended block from the
  `exec` tool, so the marker below is the pinned Codex output format. Recheck it
  when the Codex pin changes.
  """

  @exec_declaration_marker "\n\nexec tool declaration:\n"

  @doc """
  Returns one tool description without an appended `exec` declaration.
  """
  @spec plain_description(String.t() | nil) :: String.t() | nil
  def plain_description(nil), do: nil

  def plain_description(description) when is_binary(description) do
    case String.split(description, @exec_declaration_marker, parts: 2) do
      [plain, _declaration] -> plain
      [description] -> description
    end
  end

  @doc """
  Returns one Responses request whose declared tools carry plain descriptions.

  A namespace container and each of its children use the same rule. A tool
  without a description stays unchanged.
  """
  @spec plain_tool_descriptions(map()) :: map()
  def plain_tool_descriptions(%{"tools" => tools} = request) when is_list(tools),
    do: Map.put(request, "tools", Enum.map(tools, &plain_tool/1))

  def plain_tool_descriptions(%{} = request), do: request

  defp plain_tool(%{"tools" => children} = namespace) when is_list(children) do
    namespace
    |> plain_tool_description()
    |> Map.put("tools", Enum.map(children, &plain_tool/1))
  end

  defp plain_tool(%{} = tool), do: plain_tool_description(tool)
  defp plain_tool(tool), do: tool

  defp plain_tool_description(%{"description" => description} = tool)
       when is_binary(description),
       do: Map.put(tool, "description", plain_description(description))

  defp plain_tool_description(tool), do: tool
end
