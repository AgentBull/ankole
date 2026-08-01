defmodule Ankole.AIGateway.ChatGPTProtocolTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ChatGPTProtocol

  @lite_marker "ws_request_header_x_openai_internal_codex_responses_lite"

  test "prepares the complete Codex body contract and strips orphan reasoning ids" do
    request = %{
      "model" => "gpt-5.6-sol",
      "generate" => true,
      "max_output_tokens" => 8_192,
      "metadata" => %{"actor_event_id" => "event-1"},
      "prompt_cache_retention" => "24h",
      "safety_identifier" => "unsafe-upstream-field",
      "stream_options" => %{"include_usage" => true},
      "instructions" => nil,
      "parallel_tool_calls" => true,
      "tools" => [],
      "include" => ["message.output_text.logprobs"],
      "input" => [
        %{
          "id" => "rs_orphan",
          "type" => "reasoning",
          "summary" => [%{"type" => "summary_text", "text" => "summary"}]
        },
        %{
          "id" => "rs_encrypted",
          "type" => "reasoning",
          "encrypted_content" => "encrypted-state",
          "summary" => []
        }
      ]
    }

    assert {:ok, %{request: prepared, cache_key: "thread-contract", lite?: false}} =
             ChatGPTProtocol.prepare(request, %{
               "cache_key" => "thread-contract",
               "headers" => %{}
             })

    refute Map.has_key?(prepared, "generate")
    refute Map.has_key?(prepared, "max_output_tokens")
    refute Map.has_key?(prepared, "metadata")
    refute Map.has_key?(prepared, "prompt_cache_retention")
    refute Map.has_key?(prepared, "safety_identifier")
    refute Map.has_key?(prepared, "stream_options")
    refute Map.has_key?(prepared, "parallel_tool_calls")
    assert prepared["instructions"] == ""
    assert prepared["store"] == false
    assert prepared["prompt_cache_key"] == "thread-contract"

    assert prepared["include"] == [
             "reasoning.encrypted_content",
             "message.output_text.logprobs"
           ]

    assert [
             %{"type" => "reasoning", "summary" => [_summary]},
             %{
               "id" => "rs_encrypted",
               "type" => "reasoning",
               "encrypted_content" => "encrypted-state"
             }
           ] = prepared["input"]
  end

  test "rejects provider-state leakage, explicit storage, and overlong input ids" do
    context = %{"cache_key" => "thread-errors", "headers" => %{}}

    assert {:error, :chatgpt_subscription_store_forbidden} =
             ChatGPTProtocol.prepare(%{"store" => true, "input" => []}, context)

    assert {:error, :chatgpt_subscription_previous_response_id_leaked} =
             ChatGPTProtocol.prepare(
               %{"previous_response_id" => "resp_internal", "input" => []},
               context
             )

    overlong_id = String.duplicate("x", 65)

    assert {:error, {:chatgpt_subscription_input_id_too_long, ^overlong_id}} =
             ChatGPTProtocol.prepare(
               %{"input" => [%{"id" => overlong_id, "type" => "message"}]},
               context
             )
  end

  test "normalizes standard string input to the Codex input-item list" do
    assert {:ok, %{request: prepared}} =
             ChatGPTProtocol.prepare(
               %{"input" => "Call the verification tool."},
               %{"cache_key" => "thread-string-input", "headers" => %{}}
             )

    assert prepared["input"] == [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [
                 %{"type" => "input_text", "text" => "Call the verification tool."}
               ]
             }
           ]
  end

  test "keeps parallel tool calls only when a standard request has tools" do
    context = %{"cache_key" => "thread-tools", "headers" => %{}}

    assert {:ok, %{request: with_tools}} =
             ChatGPTProtocol.prepare(
               %{
                 "input" => [],
                 "parallel_tool_calls" => true,
                 "tools" => [%{"type" => "function", "name" => "weather"}]
               },
               context
             )

    assert with_tools["parallel_tool_calls"] == true

    assert {:ok, %{request: without_tools}} =
             ChatGPTProtocol.prepare(
               %{"input" => [], "parallel_tool_calls" => false},
               context
             )

    refute Map.has_key?(without_tools, "parallel_tool_calls")
  end

  test "restores a codex responses-lite request for a standard provider" do
    request = %{
      "model" => "gpt-5.6",
      "instructions" => "",
      "tools" => nil,
      "parallel_tool_calls" => false,
      "client_metadata" => %{@lite_marker => "true", "trace_id" => "trace-1"},
      "input" => [
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [%{"type" => "function", "name" => "weather"}]
        },
        %{
          "type" => "message",
          "role" => "developer",
          "content" => [%{"type" => "input_text", "text" => "Base instructions"}]
        },
        %{"type" => "message", "role" => "user", "content" => "Hello"}
      ]
    }

    assert {:ok, restored} =
             ChatGPTProtocol.normalize_non_subscription(request, %{
               "headers" => %{"x-openai-internal-codex-responses-lite" => "true"}
             })

    assert restored["instructions"] == "Base instructions"
    assert [%{"name" => "weather"}] = restored["tools"]
    assert [%{"role" => "user"}] = restored["input"]
    assert restored["client_metadata"] == %{"trace_id" => "trace-1"}
  end

  test "preserves a responses-lite request for the subscription protocol" do
    request = %{
      "model" => "gpt-5.6",
      "tools" => nil,
      "parallel_tool_calls" => false,
      "client_metadata" => %{@lite_marker => "true"},
      "input" => [
        %{
          "type" => "additional_tools",
          "role" => "developer",
          "tools" => [%{"type" => "function", "name" => "weather"}]
        }
      ]
    }

    assert {:ok, %{request: prepared, lite?: true}} =
             ChatGPTProtocol.prepare(request, %{
               "cache_key" => "thread-1",
               "headers" => %{}
             })

    assert prepared["tools"] == nil
    assert hd(prepared["input"])["type"] == "additional_tools"
    assert prepared["parallel_tool_calls"] == false
  end
end
