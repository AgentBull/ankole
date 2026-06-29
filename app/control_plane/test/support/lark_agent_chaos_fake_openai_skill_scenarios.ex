defmodule Ankole.LarkAgentChaos.FakeOpenAISkillScenarios do
  @moduledoc """
  Deterministic skill tool calls for the Lark Docker worker chaos suite.

  These calls stay separate from the main fake upstream classifier so adding
  skill coverage does not turn one scenario file back into a large catch-all.
  """

  @doc """
  Returns a skill-related OpenAI-compatible tool call for a scenario turn.
  """
  @spec tool_call_for(atom(), pos_integer()) :: map() | nil
  def tool_call_for(:skill_view_tool, 1), do: skill_view_tool_call("nano-pdf")

  def tool_call_for(:skill_view_all_tool, 1), do: skill_view_tool_call("jupyter-live-kernel")
  def tool_call_for(:skill_view_all_tool, 2), do: skill_view_tool_call("nano-pdf")
  def tool_call_for(:skill_view_all_tool, 3), do: skill_view_tool_call("powerpoint")

  def tool_call_for(:skill_append_tool, 1) do
    %{
      id: "call_lark_chaos_skill_append",
      name: "skill_append",
      arguments: %{
        "name" => "nano-pdf",
        "content" => "Lark fake overlay: CHAOS_SKILL_APPEND_OK"
      }
    }
  end

  def tool_call_for(:skill_disabled_tool, 1),
    do: skill_view_tool_call("nano-pdf", "call_lark_chaos_disabled_skill_view")

  def tool_call_for(_kind, _count), do: nil

  defp skill_view_tool_call(name, id \\ nil) do
    %{
      id: id || "call_lark_chaos_skill_view_#{String.replace(name, "-", "_")}",
      name: "skill_view",
      arguments: %{"name" => name}
    }
  end
end
