defmodule BullX.LLM.Providers.OpenAI.ResponsesAPITest do
  use ExUnit.Case, async: true

  alias BullX.LLM.Providers.OpenAI.ResponsesAPI
  alias ReqLLM.Message.ContentPart

  test "build_request_body keeps input items in message order" do
    messages = [
      %ReqLLM.Message{
        role: :user,
        content: [ContentPart.text("one")]
      },
      %ReqLLM.Message{
        role: :assistant,
        content: [ContentPart.text("two")]
      },
      %ReqLLM.Message{
        role: :user,
        content: [ContentPart.text("three")]
      }
    ]

    body =
      ResponsesAPI.build_request_body(
        %ReqLLM.Context{messages: messages},
        "gpt-test",
        [provider_options: [store: false]],
        nil
      )

    assert [
             %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "one"}]},
             %{
               "role" => "assistant",
               "content" => [%{"type" => "output_text", "text" => "two"}]
             },
             %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "three"}]}
           ] = body["input"]
  end
end
