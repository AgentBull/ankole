defmodule Ankole.Conversations.Delivery.TextTest do
  use ExUnit.Case, async: true

  alias Ankole.Conversations.Delivery.Text

  # OpenAI-style inline citation delimiters (Private Use Area).
  @e200 <<0xE200::utf8>>
  @e201 <<0xE201::utf8>>
  @e202 <<0xE202::utf8>>

  defp citation(refs), do: @e200 <> "cite" <> @e202 <> Enum.join(refs, @e202) <> @e201

  describe "normalize_visible_text/1" do
    test "strips a provider citation token span" do
      text = "结论。" <> citation(["turn0search0"]) <> " 继续"
      assert Text.normalize_visible_text(text) == "结论。 继续"
    end

    test "strips every citation span in the text" do
      text = "A" <> citation(["turn0search0"]) <> "B" <> citation(["turn1search2"]) <> "C"
      assert Text.normalize_visible_text(text) == "ABC"
    end

    test "keeps ordinary reply text and trims surrounding whitespace" do
      assert Text.normalize_visible_text("  hello world  ") == "hello world"
    end

    test "returns empty string for non-binary input" do
      assert Text.normalize_visible_text(nil) == ""
    end
  end

  describe "visible_text/1" do
    test "chat text chooses assistant parts, concatenates, and accepts historical strings" do
      items = [
        %{"type" => "message", "role" => "user", "content" => "private input"},
        %{"type" => "reasoning", "content" => [%{"type" => "text", "text" => "draft"}]},
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{"type" => "output_text", "text" => "  first"},
            %{"type" => "reasoning_text", "text" => "hidden"}
          ]
        },
        %{"type" => "message", "content" => " second"},
        %{"type" => "text", "text" => citation(["ref"]) <> " third  "}
      ]

      assert Text.visible_text(items) == "first second third"
    end

    test "returns the cleaned assistant text with citation tokens removed" do
      items = [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => "见此" <> citation(["turn0search0"])
        }
      ]

      assert Text.visible_text(items) == "见此"
    end
  end
end
