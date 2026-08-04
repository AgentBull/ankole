defmodule Ankole.AIGateway.CodexModelBindingTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CodexModelBinding

  test "decodes one frozen binding and preserves every provider option" do
    encoded =
      %{
        "selector" => "openrouter/openai/gpt-5.6-sol",
        "provider_options" => %{
          "reasoningEffort" => "xhigh",
          "nested" => %{"preserved" => true},
          "values" => ["one", 2, false]
        },
        "supports_parallel_tool_calls" => true
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
             "supports_parallel_tool_calls" => true
           }
  end

  test "applies the frozen Job route over conflicting Codex request values" do
    binding = %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{
        "reasoningEffort" => "xhigh",
        "textVerbosity" => "low"
      },
      "supports_parallel_tool_calls" => true
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
             "reasoning" => %{"effort" => "xhigh", "summary" => "auto"}
           }
  end

  test "keeps request reasoning when the Job binding does not choose an effort" do
    binding = %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{},
      "supports_parallel_tool_calls" => false
    }

    request = %{"reasoning" => %{"effort" => "low", "summary" => "auto"}}

    assert CodexModelBinding.apply(request, binding)["reasoning"] == request["reasoning"]
  end

  test "keeps Responses Lite serial even when the provider supports parallel calls" do
    binding = %{
      "selector" => "openrouter/openai/gpt-5.6-sol",
      "provider_options" => %{},
      "supports_parallel_tool_calls" => true
    }

    request = %{
      "client_metadata" => %{
        "ws_request_header_x_openai_internal_codex_responses_lite" => "true"
      },
      "parallel_tool_calls" => true
    }

    assert CodexModelBinding.apply(request, binding)["parallel_tool_calls"] == false

    assert CodexModelBinding.apply(request, binding, responses_lite?: true)[
             "parallel_tool_calls"
           ] == false
  end

  test "rejects malformed or incomplete bindings" do
    for value <- ["not-base64", Base.url_encode64("{}", padding: false)] do
      assert {:error, :invalid_codex_model_binding} = CodexModelBinding.decode(value)
    end
  end
end
