defmodule Ankole.AIGateway.ProviderSealedContentTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderSealedContent

  @reasoning %{
    "id" => "rs_1",
    "type" => "reasoning",
    "encrypted_content" => "sealed-by-openai",
    "summary" => []
  }

  @call %{
    "id" => "fc_1",
    "type" => "function_call",
    "call_id" => "call_1",
    "name" => "send_to_agent",
    "arguments" => ~s({"thread":"t1","message":"ciphertext"}),
    "encrypted_function_args" => ["message"]
  }

  @output %{
    "type" => "function_call_output",
    "call_id" => "call_1",
    "output" => "the sub agent finished"
  }

  @message %{
    "type" => "message",
    "role" => "user",
    "content" => [%{"type" => "input_text", "text" => "keep going"}]
  }

  # Only the WebSocket resolves an anchor into history. An HTTP caller that
  # names stored history must be refused, never served a summary of the inline
  # input with the named history silently dropped.
  test "a stateless entrypoint refuses a request that names stored history" do
    assert {:error, {:stateful_http_field_forbidden, "previous_response_id"}} =
             AIGateway.ensure_stateless_request(%{
               "model" => "primary",
               "previous_response_id" => "resp_01a00000-0000-7000-8000-000000000000",
               "input" => [%{"type" => "compaction_trigger"}]
             })

    assert {:error, {:stateful_http_field_forbidden, "conversation"}} =
             AIGateway.ensure_stateless_request(%{"conversation" => "conv_x"})

    assert :ok = AIGateway.ensure_stateless_request(%{"model" => "primary", "store" => false})
  end

  test "the same issuer reads its own sealed state unchanged" do
    items = [@message, @reasoning, @call, @output]

    assert ProviderSealedContent.strip_foreign(items, "openai-main", "openai-main") == items
  end

  test "history stored before AIGateway recorded an issuer replays unchanged" do
    items = [@reasoning, @call]

    assert ProviderSealedContent.strip_foreign(items, "openai-main", nil) == items
    assert ProviderSealedContent.strip_foreign(items, nil, "openai-main") == items
  end

  test "another issuer loses the sealed content and keeps every structure" do
    items = [@message, @reasoning, @call, @output]

    assert [message, call, output] =
             ProviderSealedContent.strip_foreign(items, "anthropic-main", "openai-main")

    # Reasoning is the only item nothing pairs with, so it is the only one that
    # leaves. The call keeps its pair, so the conversation still runs.
    assert message == @message
    assert output == @output
    assert call["call_id"] == "call_1"
    assert call["name"] == "send_to_agent"

    # The sealed parameter becomes plain and the marker goes with it. The
    # unsealed parameter is untouched.
    refute Map.has_key?(call, "encrypted_function_args")
    assert {:ok, arguments} = Ankole.JSON.decode(call["arguments"])
    assert arguments["thread"] == "t1"
    assert arguments["message"] =~ "unavailable"
  end

  test "a reasoning item without ciphertext carries only a public summary and stays" do
    summary_only = %{"id" => "rs_2", "type" => "reasoning", "summary" => ["planned the edit"]}

    assert ProviderSealedContent.strip_foreign(
             [summary_only],
             "anthropic-main",
             "openai-main"
           ) == [summary_only]
  end

  test "sealed content nested inside a content part goes too" do
    output_with_sealed_part = %{
      "type" => "function_call_output",
      "call_id" => "call_1",
      "output" => [
        %{"type" => "encrypted_content", "encrypted_content" => "sealed-by-openai"},
        %{"type" => "output_text", "text" => "the readable result"}
      ]
    }

    assert [output] =
             ProviderSealedContent.strip_foreign(
               [output_with_sealed_part],
               "anthropic-main",
               "openai-main"
             )

    assert output["call_id"] == "call_1"
    assert output["output"] == [%{"type" => "output_text", "text" => "the readable result"}]
  end

  test "a compaction item holding another Provider's state does not replay" do
    items = [
      %{"type" => "compaction", "encrypted_content" => "provider-sealed-blob"},
      %{"type" => "context_compaction", "encrypted_content" => "provider-sealed-blob"},
      @message
    ]

    assert ProviderSealedContent.strip_foreign(items, "anthropic-main", "openai-main") == [
             @message
           ]
  end

  test "a call that carries its sealed parameters in input keeps every other field" do
    custom_call = %{
      "type" => "custom_tool_call",
      "call_id" => "call_2",
      "name" => "send_to_agent",
      "input" => ~s({"message":"ciphertext"}),
      "encrypted_function_args" => ["message"]
    }

    assert [call] =
             ProviderSealedContent.strip_foreign([custom_call], "anthropic-main", "openai-main")

    # No `arguments` field is invented for a call that never had one.
    refute Map.has_key?(call, "arguments")
    assert call["call_id"] == "call_2"
    assert {:ok, %{"message" => value}} = Ankole.JSON.decode(call["input"])
    assert value =~ "unavailable"
  end

  test "arguments AIGateway cannot parse still become plain rather than staying sealed" do
    unreadable = Map.put(@call, "arguments", "not-json")

    assert [call] =
             ProviderSealedContent.strip_foreign([unreadable], "anthropic-main", "openai-main")

    refute Map.has_key?(call, "encrypted_function_args")
    assert {:ok, %{"message" => value}} = Ankole.JSON.decode(call["arguments"])
    assert value =~ "unavailable"
  end
end
