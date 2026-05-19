defmodule BullX.AIAgent.SystemPromptBuilderTest do
  use ExUnit.Case, async: true

  alias BullX.AIAgent.SystemPromptBuilder

  test "renders stable sections before volatile sections with deterministic boundary" do
    sections = [
      %SystemPromptBuilder.Section{
        id: "runtime.current",
        kind: :runtime,
        stability: :volatile,
        priority: 0,
        cache_break_reason: "current input",
        content: "now"
      },
      %SystemPromptBuilder.Section{
        id: "profile.instructions",
        kind: :profile,
        stability: :stable,
        priority: 10,
        content: "follow policy"
      },
      %SystemPromptBuilder.Section{
        id: "profile.empty",
        kind: :profile,
        stability: :stable,
        content: nil
      }
    ]

    assert {:ok, rendered} = SystemPromptBuilder.render(sections)
    assert rendered.system_text == "follow policy\n\nnow"
    assert rendered.stable_prefix.last_stable_section_id == "profile.instructions"
    assert rendered.stable_prefix.stable_section_count == 1
    assert rendered.stable_prefix.byte_offset == byte_size("follow policy")
    assert rendered.diagnostics.omitted_section_ids == ["profile.empty"]
  end

  test "rejects duplicate ids and empty content" do
    duplicate = [
      %SystemPromptBuilder.Section{id: "a", kind: :x, stability: :stable, content: "one"},
      %SystemPromptBuilder.Section{id: "a", kind: :x, stability: :stable, content: "two"}
    ]

    assert {:error, {:system_prompt_builder, :duplicate_section_id, %{section_id: "a"}}} =
             SystemPromptBuilder.render(duplicate)

    assert {:error, {:system_prompt_builder, :empty_content, %{section_id: "a"}}} =
             SystemPromptBuilder.render([
               %SystemPromptBuilder.Section{id: "a", kind: :x, stability: :stable, content: ""}
             ])
  end

  test "rejects malformed map input and unsafe content metadata" do
    assert {:error, {:system_prompt_builder, :missing_required_field, %{field: "content"}}} =
             SystemPromptBuilder.render([
               %{"id" => "a", "kind" => :runtime, "stability" => :stable}
             ])

    assert {:error, {:system_prompt_builder, :invalid_content, %{section_id: "a"}}} =
             SystemPromptBuilder.render([
               %{"id" => "a", "kind" => :runtime, "stability" => :stable, "content" => false}
             ])

    assert {:error, {:system_prompt_builder, :forbidden_content_metadata, %{section_id: "a"}}} =
             SystemPromptBuilder.render([
               %{
                 "id" => "a",
                 "kind" => :runtime,
                 "stability" => :stable,
                 "content" => [
                   %{"type" => "text", "text" => "safe text", "metadata" => %{"api_key" => false}}
                 ]
               }
             ])
  end

  test "rejects invalid text and ignores stable cache break reasons" do
    assert {:error, {:system_prompt_builder, :invalid_content, %{section_id: "a"}}} =
             SystemPromptBuilder.render([
               %SystemPromptBuilder.Section{
                 id: "a",
                 kind: :runtime,
                 stability: :volatile,
                 content: "bad\r\ntext",
                 cache_break_reason: "current input"
               }
             ])

    invalid_utf8 = <<0xFF, 0xFE>>

    assert {:error, {:system_prompt_builder, :invalid_content, %{section_id: "a"}}} =
             SystemPromptBuilder.render([
               %SystemPromptBuilder.Section{
                 id: "a",
                 kind: :runtime,
                 stability: :stable,
                 content: invalid_utf8,
                 cache_break_reason: "ignored for stable section"
               }
             ])

    assert {:ok, rendered} =
             SystemPromptBuilder.render([
               %SystemPromptBuilder.Section{
                 id: "a",
                 kind: :runtime,
                 stability: :stable,
                 content: "stable",
                 cache_break_reason: "ignored for stable section"
               }
             ])

    assert rendered.system_text == "stable"
  end
end
