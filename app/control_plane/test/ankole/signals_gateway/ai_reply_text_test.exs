defmodule Ankole.SignalsGateway.AIReplyTextTest do
  use ExUnit.Case, async: true

  alias Ankole.SignalsGateway.AIReplyText

  # OpenAI-style inline citation delimiters (Private Use Area).
  @e200 <<0xE200::utf8>>
  @e201 <<0xE201::utf8>>
  @e202 <<0xE202::utf8>>

  defp citation(refs), do: @e200 <> "cite" <> @e202 <> Enum.join(refs, @e202) <> @e201

  describe "normalize_visible_text/1" do
    test "strips a provider citation token span" do
      text = "结论。" <> citation(["turn0search0"]) <> " 继续"
      assert AIReplyText.normalize_visible_text(text) == "结论。 继续"
    end

    test "strips every citation span in the text" do
      text = "A" <> citation(["turn0search0"]) <> "B" <> citation(["turn1search2"]) <> "C"
      assert AIReplyText.normalize_visible_text(text) == "ABC"
    end

    test "strips the silent-success sentinel so it can never reach a channel" do
      assert AIReplyText.normalize_visible_text("<silent_success/>") == ""
      assert AIReplyText.normalize_visible_text("done <silent_success/>") == "done"
    end

    test "keeps ordinary reply text and trims surrounding whitespace" do
      assert AIReplyText.normalize_visible_text("  hello world  ") == "hello world"
    end

    test "returns empty string for non-binary input" do
      assert AIReplyText.normalize_visible_text(nil) == ""
    end
  end

  describe "visible_text/1" do
    test "collapses a sentinel-only assistant message to nil" do
      items = [%{"type" => "message", "role" => "assistant", "content" => "<silent_success/>"}]
      assert AIReplyText.visible_text(items) == nil
    end

    test "returns the cleaned assistant text with citation tokens removed" do
      items = [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => "见此" <> citation(["turn0search0"])
        }
      ]

      assert AIReplyText.visible_text(items) == "见此"
    end
  end
end
