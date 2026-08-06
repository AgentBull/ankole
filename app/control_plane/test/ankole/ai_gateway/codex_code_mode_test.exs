defmodule Ankole.AIGateway.CodexCodeModeTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CodexCodeMode

  @plain "Look up one record."
  @declaration "\n\nexec tool declaration:\n```ts\ndeclare const tools: { lookup(args: {\n" <>
                 "  // Record id.\n  id: string;\n}): Promise<unknown>; };\n```"
  @augmented @plain <> @declaration

  describe "plain_description/1" do
    test "removes the appended exec declaration" do
      assert CodexCodeMode.plain_description(@augmented) == @plain
    end

    test "keeps a description that carries no declaration" do
      assert CodexCodeMode.plain_description(@plain) == @plain
      assert CodexCodeMode.plain_description(nil) == nil
    end

    test "returns an empty description when the tool documented nothing else" do
      assert CodexCodeMode.plain_description(@declaration) == ""
    end
  end

  describe "plain_tool_descriptions/1" do
    test "restores root tools, namespace children, and leaves other tools alone" do
      request = %{
        "model" => "primary",
        "tools" => [
          %{"type" => "function", "name" => "lookup", "description" => @augmented},
          %{"type" => "custom", "name" => "apply_patch", "description" => @augmented},
          %{
            "type" => "namespace",
            "name" => "skills",
            "description" => "Agent Skills.",
            "tools" => [%{"type" => "function", "name" => "read", "description" => @augmented}]
          },
          %{"type" => "web_search"}
        ]
      }

      assert %{"tools" => tools, "model" => "primary"} =
               CodexCodeMode.plain_tool_descriptions(request)

      assert [lookup, apply_patch, namespace, web_search] = tools
      assert lookup == %{"type" => "function", "name" => "lookup", "description" => @plain}

      assert apply_patch == %{
               "type" => "custom",
               "name" => "apply_patch",
               "description" => @plain
             }

      assert namespace["description"] == "Agent Skills."
      assert [%{"name" => "read", "description" => @plain}] = namespace["tools"]
      assert web_search == %{"type" => "web_search"}
    end

    test "keeps a request that declares no tools" do
      request = %{"model" => "primary", "input" => "hello"}

      assert CodexCodeMode.plain_tool_descriptions(request) == request
    end
  end
end
