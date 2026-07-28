defmodule Ankole.AIGateway.OpaqueContentTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.OpaqueContent

  @opaque_value "ankole-aigateway-opaque-v1:" <>
                  Base.url_encode64("history secret", padding: false)

  test "reveals a whole opaque string value" do
    assert OpaqueContent.reveal(@opaque_value) == "history secret"
  end

  test "reveals the legacy chat prefix" do
    legacy = "ankole-chat-encoded-v1:" <> Base.url_encode64("legacy", padding: false)
    assert OpaqueContent.reveal(legacy) == "legacy"
  end

  test "reveals opaque values inside tool-call arguments JSON" do
    message = %{
      "role" => "assistant",
      "tool_calls" => [
        %{
          "id" => "call_1",
          "type" => "function",
          "function" => %{
            "name" => "collaboration.send_message",
            "arguments" => Ankole.JSON.encode!(%{"message" => @opaque_value, "task_name" => "t"})
          }
        }
      ]
    }

    [revealed] = OpaqueContent.reveal([message])

    arguments =
      revealed["tool_calls"]
      |> hd()
      |> get_in(["function", "arguments"])
      |> Ankole.JSON.decode!()

    assert arguments == %{"message" => "history secret", "task_name" => "t"}
  end

  test "keeps a quoted prefix inside a longer value verbatim" do
    command = "rg '#{@opaque_value}' logs/"
    arguments = Ankole.JSON.encode!(%{"cmd" => command})

    revealed = OpaqueContent.reveal(%{"arguments" => arguments})

    assert Ankole.JSON.decode!(revealed["arguments"]) == %{"cmd" => command}
  end

  test "keeps a corrupt opaque value verbatim" do
    corrupt = "ankole-aigateway-opaque-v1:!!not-base64!!"
    assert OpaqueContent.reveal(corrupt) == corrupt
  end

  test "keeps non-string values untouched" do
    assert OpaqueContent.reveal(%{"count" => 3, "flag" => true, "none" => nil}) ==
             %{"count" => 3, "flag" => true, "none" => nil}
  end
end
