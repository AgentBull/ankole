defmodule Ankole.Sessions.CodexModelBindingTest do
  use ExUnit.Case, async: true

  alias Ankole.Sessions.CodexModelBinding

  test "decodes the exact headers produced by the Worker shared wire corpus" do
    vectors =
      __DIR__
      |> Path.join(
        "../../../../kernel/proto/ankole/runtime_fabric/v1/codex_model_binding_vectors.json"
      )
      |> File.read!()
      |> Ankole.JSON.decode!()

    for vector <- vectors["valid"] do
      assert CodexModelBinding.decode(vector["encoded"]) == {:ok, vector["binding"]}
    end
  end

  test "decodes one frozen binding and preserves every provider option" do
    encoded =
      %{
        "selector" => "openrouter/openai/gpt-5.6-sol",
        "provider_options" => %{
          "reasoningEffort" => "xhigh",
          "nested" => %{"preserved" => true},
          "values" => ["one", 2, false]
        },
        "supports_parallel_tool_calls" => true,
        "input_modalities" => ["text"],
        "vision_fallback" => %{
          "selector" => "openrouter/google/gemini-3-flash-preview",
          "provider_options" => %{"serviceTier" => "priority"},
          "input_modalities" => ["text", "image"]
        }
      }
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, binding} = CodexModelBinding.decode(encoded)

    assert binding == %{
             "selector" => "openrouter/openai/gpt-5.6-sol",
             "provider_options" => %{
               "reasoningEffort" => "xhigh",
               "nested" => %{"preserved" => true},
               "values" => ["one", 2, false]
             },
             "supports_parallel_tool_calls" => true,
             "input_modalities" => ["text"],
             "vision_fallback" => %{
               "selector" => "openrouter/google/gemini-3-flash-preview",
               "provider_options" => %{"serviceTier" => "priority"},
               "input_modalities" => ["text", "image"]
             }
           }
  end

  test "applies the frozen Job route over conflicting Codex request values" do
    binding = %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{
        "reasoningEffort" => "xhigh",
        "textVerbosity" => "low"
      },
      "supports_parallel_tool_calls" => true,
      "input_modalities" => ["text"],
      "vision_fallback" => %{
        "selector" => "openrouter/google/gemini-3-flash-preview",
        "provider_options" => %{},
        "input_modalities" => ["text", "image"]
      }
    }

    assert CodexModelBinding.apply(
             %{
               "model" => "gpt-5.6-sol",
               "provider_options" => %{"textVerbosity" => "high"},
               "reasoning" => %{"effort" => "minimal", "summary" => "auto"},
               "parallel_tool_calls" => false
             },
             binding
           ) == %{
             "model" => "openrouter/openai/gpt-5.6-sol",
             "parallel_tool_calls" => true,
             "provider_options" => %{
               "reasoningEffort" => "xhigh",
               "textVerbosity" => "low"
             },
             "reasoning" => %{"effort" => "xhigh", "summary" => "auto"},
             "__ankole_codex_vision" => %{
               "input_modalities" => ["text"],
               "vision_fallback" => %{
                 "selector" => "openrouter/google/gemini-3-flash-preview",
                 "provider_options" => %{},
                 "input_modalities" => ["text", "image"]
               }
             }
           }
  end

  test "keeps request reasoning when the Job binding does not choose an effort" do
    binding = %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{},
      "supports_parallel_tool_calls" => false,
      "input_modalities" => ["text", "image"]
    }

    request = %{"reasoning" => %{"effort" => "low", "summary" => "auto"}}

    assert CodexModelBinding.apply(request, binding)["reasoning"] == request["reasoning"]
  end

  test "keeps Responses Lite serial even when the provider supports parallel calls" do
    binding = %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{},
      "supports_parallel_tool_calls" => true,
      "input_modalities" => ["text"]
    }

    request = %{
      "client_metadata" => %{
        "ws_request_header_x_openai_internal_codex_responses_lite" => "true"
      },
      "parallel_tool_calls" => true
    }

    assert CodexModelBinding.apply(request, binding)["parallel_tool_calls"] == false

    plain = Map.delete(request, "client_metadata")

    assert CodexModelBinding.apply(plain, binding, %{
             "headers" => %{"x-openai-internal-codex-responses-lite" => "true"}
           })["parallel_tool_calls"] == false

    assert CodexModelBinding.apply(plain, binding, %{})["parallel_tool_calls"] == true
  end

  test "bound Codex requests drop OpenAI-only replay fields" do
    binding = %{
      "selector" => "primary",
      "provider_options" => %{},
      "supports_parallel_tool_calls" => true,
      "input_modalities" => ["text"]
    }

    request = %{
      "input" => [
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "encrypted_function_args" => ["secret"],
          "internal_chat_message_metadata_passthrough" => %{"turn_id" => "turn-1"}
        },
        %{"type" => "compaction_trigger"}
      ]
    }

    assert [item, %{"type" => "compaction_trigger"}] =
             CodexModelBinding.apply(request, binding)["input"]

    refute Map.has_key?(item, "encrypted_function_args")
    refute Map.has_key?(item, "internal_chat_message_metadata_passthrough")
    assert CodexModelBinding.apply(request, nil) == request
  end

  test "rejects malformed or incomplete bindings" do
    for value <- ["not-base64", Base.url_encode64("{}", padding: false)] do
      assert {:error, :invalid_codex_model_binding} = CodexModelBinding.decode(value)
    end
  end

  test "a Job binding never declares the hosted Brain tool in the Codex request" do
    # A codex Job reaches `recall` and `get_page` through the Worker read-tool
    # bridge. The binding leaves the Codex tool list, its `additional_tools`
    # carrier, and the request metadata as Codex sent them, so one tool name
    # has one executor.
    signal_id = Ankole.Ecto.UUIDv7.autogenerate()

    binding = %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{},
      "supports_parallel_tool_calls" => true,
      "input_modalities" => ["text"],
      "job" => %{"id" => 1155, "attempt" => 2, "signal_id" => signal_id}
    }

    tools = [%{"type" => "function", "name" => "shell", "parameters" => %{}}]

    applied =
      CodexModelBinding.apply(
        %{
          "model" => "codex-mini",
          "input" => [],
          "tools" => tools,
          "metadata" => %{"trace" => "abc"}
        },
        binding
      )

    assert applied["tools"] == tools
    assert applied["metadata"] == %{"trace" => "abc"}
    assert {:ok, nil} = Ankole.AIGateway.HostedTools.Brain.declaration(applied)

    carrier = %{"type" => "additional_tools", "role" => "developer", "tools" => tools}
    message = %{"type" => "message", "role" => "user", "content" => "hello"}

    carried =
      CodexModelBinding.apply(%{"model" => "codex-mini", "input" => [carrier, message]}, binding)

    assert carried["tools"] == nil
    assert carried["input"] == [carrier, message]
    assert {:ok, nil} = Ankole.AIGateway.HostedTools.Brain.declaration(carried)
  end

  test "rejects a fallback that cannot receive images" do
    encoded =
      %{
        "selector" => "openrouter/openai/gpt-5.6-sol",
        "provider_options" => %{},
        "supports_parallel_tool_calls" => true,
        "input_modalities" => ["text"],
        "vision_fallback" => %{
          "selector" => "openrouter/text-only",
          "provider_options" => %{},
          "input_modalities" => ["text"]
        }
      }
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:error, :invalid_codex_model_binding} = CodexModelBinding.decode(encoded)
  end

  describe "job attribution" do
    @signal_id "01915f9d-5f00-7000-8000-000000000001"

    test "decodes the Job attempt and writes it into the request context" do
      encoded =
        encode_binding(%{"job" => %{"id" => 1234, "attempt" => 3, "signal_id" => @signal_id}})

      assert {:ok, binding} = CodexModelBinding.decode(encoded)
      assert binding["job"] == %{"id" => 1234, "attempt" => 3, "signal_id" => @signal_id}

      context =
        CodexModelBinding.request_context(binding, %{
          "headers" => %{"originator" => "codex_cli_rs"},
          "downstream_transport" => "http"
        })

      assert context == %{
               "headers" => %{"originator" => "codex_cli_rs"},
               "downstream_transport" => "http",
               "job_id" => 1234,
               "attempts" => 3,
               "signal_id" => @signal_id,
               "session_id" => "job:1234"
             }
    end

    test "a binding without a Job leaves the request context unchanged" do
      assert {:ok, binding} = CodexModelBinding.decode(encode_binding(%{}))
      refute Map.has_key?(binding, "job")
      context = %{"headers" => %{}, "downstream_transport" => "websocket"}
      assert CodexModelBinding.request_context(binding, context) == context
      assert CodexModelBinding.request_context(nil, context) == context
    end

    for job <- [
          %{"id" => 0, "attempt" => 0, "signal_id" => @signal_id},
          %{"id" => "1234", "attempt" => 0, "signal_id" => @signal_id},
          %{"id" => 1234, "attempt" => -1, "signal_id" => @signal_id},
          %{"id" => 1234, "attempt" => 1, "signal_id" => "not-a-uuid"},
          %{"id" => 1234, "attempt" => 1},
          "job:1234"
        ] do
      @job job
      test "rejects the Job section #{inspect(@job)}" do
        assert {:error, :invalid_codex_model_binding} =
                 CodexModelBinding.decode(encode_binding(%{"job" => @job}))
      end
    end
  end

  defp encode_binding(extra) do
    %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{},
      "supports_parallel_tool_calls" => true,
      "input_modalities" => ["text"]
    }
    |> Map.merge(extra)
    |> Ankole.JSON.encode!()
    |> Base.url_encode64(padding: false)
  end
end
