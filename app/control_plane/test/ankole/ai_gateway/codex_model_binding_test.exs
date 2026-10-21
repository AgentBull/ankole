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

  test "carries the Job's hosted Brain declaration and applies it to the request" do
    signal_id = Ankole.Ecto.UUIDv7.autogenerate()

    encoded =
      %{
        "selector" => "openrouter/openai/gpt-5.6-sol",
        "provider_options" => %{},
        "supports_parallel_tool_calls" => true,
        "input_modalities" => ["text"],
        "brain" => %{"operations" => ["recall", "get_page"], "signal_id" => signal_id}
      }
      |> Ankole.JSON.encode!()
      |> Base.url_encode64(padding: false)

    assert {:ok, binding} = CodexModelBinding.decode(encoded)

    assert binding["brain"] == %{
             "operations" => ["recall", "get_page"],
             "signal_id" => signal_id
           }

    request = %{
      "model" => "codex-mini",
      "input" => [],
      "tools" => [%{"type" => "function", "name" => "shell", "parameters" => %{}}],
      "metadata" => %{"trace" => "abc"}
    }

    applied = CodexModelBinding.apply(request, binding)

    assert Enum.at(applied["tools"], -1) == %{
             "type" => "brain",
             "operations" => ["recall", "get_page"]
           }

    assert applied["metadata"] == %{"trace" => "abc", "signal_id" => signal_id}

    # Codex 0.163 carries its tools in an `additional_tools` input item. The
    # declaration must join that list; a top-level `tools` entry would stay
    # unsplit and reach the provider as an unknown tool type.
    carried =
      CodexModelBinding.apply(
        %{
          "model" => "codex-mini",
          "input" => [
            %{"type" => "additional_tools", "role" => "developer", "tools" => request["tools"]},
            %{"type" => "message", "role" => "user", "content" => "hello"}
          ]
        },
        binding
      )

    assert carried["tools"] == nil
    [carrier, _message] = carried["input"]
    assert Enum.map(carrier["tools"], & &1["type"]) == ["function", "brain"]

    assert {:ok, %{operations: ["recall", "get_page"]}} =
             Ankole.AIGateway.HostedTools.Brain.declaration(carried)
  end

  test "rejects a Brain declaration with unknown operations or no actor event" do
    for brain <- [
          %{"operations" => ["erase"], "signal_id" => "event-1"},
          %{"operations" => ["recall"], "signal_id" => ""},
          %{"operations" => [], "signal_id" => "event-1"}
        ] do
      encoded =
        %{
          "selector" => "openrouter/openai/gpt-5.6-sol",
          "provider_options" => %{},
          "supports_parallel_tool_calls" => true,
          "input_modalities" => ["text"],
          "brain" => brain
        }
        |> Ankole.JSON.encode!()
        |> Base.url_encode64(padding: false)

      assert {:error, :invalid_codex_model_binding} = CodexModelBinding.decode(encoded)
    end
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
end
