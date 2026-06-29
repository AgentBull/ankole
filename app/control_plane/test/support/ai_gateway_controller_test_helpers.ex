defmodule AnkoleWeb.AIGatewayControllerTestHelpers do
  @moduledoc """
  Shared helpers for AIGateway controller contract tests.

  These helpers keep the controller test focused on endpoint behavior while the
  verbose OpenResponses schema fixtures live in one place. They are test-only
  because production code should normalize and validate through the AIGateway
  modules, not through assertion helpers.
  """

  import ExUnit.Assertions
  import Ankole.PrincipalsFixtures
  import Plug.Conn

  alias Ankole.AuthZ
  alias Phoenix.ConnTest
  alias AnkoleWeb.ConsoleTokens

  @doc """
  Returns the stateless OpenResponses request templates used by the controller
  contract test.

  Each tuple contains a template id, a public request body, and a validator for
  the normalized downstream body plus provider-facing upstream request.
  """
  def stateless_openresponses_templates do
    noop = fn _id, _body, _request -> :ok end

    [
      {"basic-response",
       %{
         "model" => "primary",
         "input" => [
           %{"type" => "message", "role" => "user", "content" => "Say hello in exactly 3 words."}
         ]
       }, noop},
      {"assistant-phase",
       %{
         "model" => "primary",
         "input" => [
           %{
             "type" => "message",
             "role" => "assistant",
             "phase" => "commentary",
             "content" => "I should answer with the saved number."
           },
           %{
             "type" => "message",
             "role" => "assistant",
             "phase" => "final_answer",
             "content" => "The number is four."
           },
           %{"type" => "message", "role" => "user", "content" => "Repeat only the number."}
         ]
       }, noop},
      {"system-prompt",
       %{
         "model" => "primary",
         "input" => [
           %{"type" => "message", "role" => "system", "content" => "You are a pirate."},
           %{"type" => "message", "role" => "user", "content" => "Say hello."}
         ]
       },
       fn _id, _body, request ->
         assert [%{"role" => "system"} | _rest] = request.body["messages"]
       end},
      {"tool-calling",
       %{
         "model" => "primary",
         "input" => [
           %{
             "type" => "message",
             "role" => "user",
             "content" => "What's the weather like in San Francisco?"
           }
         ],
         "tools" => [
           %{
             "type" => "function",
             "name" => "get_weather",
             "description" => "Get the current weather for a location",
             "parameters" => %{
               "type" => "object",
               "properties" => %{"location" => %{"type" => "string"}},
               "required" => ["location"]
             }
           }
         ]
       },
       fn _id, body, request ->
         assert Enum.any?(body["output"], &(&1["type"] == "function_call"))

         assert [%{"strict" => nil, "description" => "Get the current weather for a location"}] =
                  body["tools"]

         assert [
                  %{
                    "type" => "function",
                    "function" => %{
                      "name" => "get_weather",
                      "description" => "Get the current weather for a location"
                    }
                  }
                ] = request.body["tools"]
       end},
      {"image-input",
       %{
         "model" => "primary",
         "input" => [
           %{
             "type" => "message",
             "role" => "user",
             "content" => [
               %{"type" => "input_text", "text" => "What do you see in this image?"},
               %{"type" => "input_image", "image_url" => "data:image/png;base64,iVBORw0KGgo="}
             ]
           }
         ]
       }, noop},
      {"multi-turn",
       %{
         "model" => "primary",
         "input" => [
           %{"type" => "message", "role" => "user", "content" => "My name is Alice."},
           %{"type" => "message", "role" => "assistant", "content" => "Hello Alice!"},
           %{"type" => "message", "role" => "user", "content" => "What is my name?"}
         ]
       }, noop}
    ]
  end

  @doc """
  Builds a minimal Chat Completions body for provider-dispatch controller tests.

  The helper intentionally switches to a function-call response when tools are
  present so one public Responses request can prove the adapter's tool-shape
  conversion in both directions.
  """
  def chat_completion_fixture(body) do
    message =
      case Map.get(body, "tools") do
        tools when is_list(tools) and tools != [] ->
          %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => "call_weather",
                "type" => "function",
                "function" => %{
                  "name" => "get_weather",
                  "arguments" => ~s({"location":"San Francisco, CA"})
                }
              }
            ]
          }

        _tools ->
          %{"role" => "assistant", "content" => "hello from compliance"}
      end

    %{
      "id" => "chatcmpl_#{System.unique_integer([:positive])}",
      "object" => "chat.completion",
      "created" => 1_764_967_971,
      "model" => body["model"],
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 7, "total_tokens" => 12}
    }
  end

  @doc """
  Returns a complete OpenResponses SSE event sequence for controller tests.

  The sequence includes lifecycle events instead of only text deltas because the
  worker validates Responses stream schema before it can retry or continue a
  turn safely.
  """
  def response_sse_events(response_id, model, text) do
    response =
      %{
        "id" => response_id,
        "object" => "response",
        "created_at" => 1_764_967_971,
        "completed_at" => nil,
        "status" => "in_progress",
        "model" => model,
        "previous_response_id" => nil,
        "output" => [],
        "usage" => %{}
      }

    item = %{
      "id" => "msg_sse",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }

    [
      %{"type" => "response.created", "sequence_number" => 0, "response" => response},
      %{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => %{item | "status" => "in_progress", "content" => []}
      },
      %{
        "type" => "response.content_part.added",
        "sequence_number" => 2,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "part" => %{"type" => "output_text", "text" => "", "annotations" => []}
      },
      %{
        "type" => "response.output_text.delta",
        "sequence_number" => 3,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "delta" => text
      },
      %{
        "type" => "response.output_text.done",
        "sequence_number" => 4,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "text" => text
      },
      %{
        "type" => "response.content_part.done",
        "sequence_number" => 5,
        "item_id" => "msg_sse",
        "output_index" => 0,
        "content_index" => 0,
        "part" => List.first(item["content"])
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => 6,
        "output_index" => 0,
        "item" => item
      },
      %{
        "type" => "response.completed",
        "sequence_number" => 7,
        "response" => %{
          response
          | "completed_at" => 1_764_967_972,
            "status" => "completed",
            "output" => [item]
        }
      }
    ]
  end

  @doc "Encodes one JSON SSE `data:` frame with the project's JSON adapter."
  def sse_data(event), do: "data: #{Ankole.JSON.encode!(event)}\n\n"

  @doc "Builds an authenticated JSON connection for AIGateway controller tests."
  def gateway_conn(api_key) do
    ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer #{api_key}")
    |> put_req_header("content-type", "application/json")
  end

  @doc "Mints an admin console access token for AIGateway controller tests."
  def admin_access_token do
    human = human_fixture(%{uid: unique_uid("ai-gateway-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    assert {:ok, token_set} =
             ConsoleTokens.mint_for_session(%{
               "principal_uid" => human.principal.uid,
               "provider_id" => "lark-main",
               "external_id" => "external-1",
               "issued_at" => System.system_time(:second),
               "expires_at" => System.system_time(:second) + 3_600
             })

    token_set.access_token
  end

  @doc "Decodes JSON events from an HTTP SSE response body."
  def decode_sse_events(response) do
    response
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn chunk ->
      chunk
      |> String.split("\n")
      |> Enum.find_value(fn
        "data: [DONE]" -> :done
        "data: " <> data -> data
        _line -> nil
      end)
      |> case do
        :done -> []
        data when is_binary(data) -> [Ankole.JSON.decode!(data)]
        _value -> []
      end
    end)
  end

  @doc """
  Asserts that every SSE `event:` field matches the decoded event body's type.

  The Responses client uses the body schema, but mismatched SSE event names make
  browser and worker logs misleading during streaming failures.
  """
  def assert_sse_event_names_match_body_types(response) do
    response
    |> String.split("\n\n", trim: true)
    |> Enum.reject(&(&1 == "data: [DONE]"))
    |> Enum.each(fn chunk ->
      lines = String.split(chunk, "\n")
      event_name = sse_field(lines, "event")
      data = sse_field(lines, "data")

      assert is_binary(event_name), "missing SSE event field in #{inspect(chunk)}"
      assert is_binary(data), "missing SSE data field in #{inspect(chunk)}"

      assert %{"type" => ^event_name} = Ankole.JSON.decode!(data)
    end)
  end

  defp sse_field(lines, field) do
    Enum.find_value(lines, fn
      line ->
        case String.split(line, ":", parts: 2) do
          [^field, value] -> String.trim_leading(value)
          _other -> nil
        end
    end)
  end

  @doc """
  Asserts the normalized body keeps the OpenResponses resource contract.

  This is intentionally stricter than the single fields used by most controller
  tests because worker retries and continuation logic depend on many nullable
  fields existing with stable names.
  """
  def assert_openresponses_response_resource(body) do
    required_keys = ~w(
      id object created_at completed_at status incomplete_details model previous_response_id
      instructions output error tools tool_choice truncation parallel_tool_calls text top_p
      presence_penalty frequency_penalty top_logprobs temperature reasoning usage
      max_output_tokens max_tool_calls store background service_tier metadata safety_identifier
      prompt_cache_key user
    )

    Enum.each(required_keys, fn key ->
      assert Map.has_key?(body, key), "missing OpenResponses response field #{key}"
    end)

    assert is_binary(body["id"])
    assert body["object"] == "response"
    assert is_integer(body["created_at"])
    assert is_nil(body["completed_at"]) or is_integer(body["completed_at"])
    assert is_binary(body["status"])
    assert is_nil(body["incomplete_details"]) or is_map(body["incomplete_details"])
    assert is_binary(body["model"])
    assert is_nil(body["previous_response_id"])
    assert is_nil(body["instructions"]) or is_binary(body["instructions"])
    assert is_list(body["input"])
    assert is_list(body["output"])
    assert is_nil(body["error"]) or is_map(body["error"])
    assert is_list(body["tools"])
    assert body["tool_choice"] in ["none", "auto", "required"] or is_map(body["tool_choice"])
    assert body["truncation"] in ["auto", "disabled"]
    assert is_boolean(body["parallel_tool_calls"])
    assert get_in(body, ["text", "format", "type"]) == "text"
    assert is_number(body["top_p"])
    assert is_number(body["presence_penalty"])
    assert is_number(body["frequency_penalty"])
    assert is_integer(body["top_logprobs"])
    assert is_number(body["temperature"])
    assert is_map(body["reasoning"])
    assert Map.has_key?(body["reasoning"], "effort")
    assert Map.has_key?(body["reasoning"], "summary")
    assert is_nil(body["user"]) or is_binary(body["user"])
    assert_response_usage(body["usage"])
    assert is_nil(body["max_output_tokens"]) or is_integer(body["max_output_tokens"])
    assert is_nil(body["max_tool_calls"]) or is_integer(body["max_tool_calls"])
    assert is_boolean(body["store"])
    assert is_boolean(body["background"])
    assert is_binary(body["service_tier"])
    assert is_map(body["metadata"])
    assert is_nil(body["safety_identifier"]) or is_binary(body["safety_identifier"])
    assert is_nil(body["prompt_cache_key"]) or is_binary(body["prompt_cache_key"])
    assert is_list(Map.get(body, "next_response_ids", []))
    assert is_list(Map.get(body, "context_edits", []))

    assert is_nil(body["prompt_cache_retention"]) or
             body["prompt_cache_retention"] in ["in_memory", "24h"]

    assert is_nil(body["conversation"]) or is_binary(body["conversation"]["id"])

    Enum.each(body["input"], &assert_openresponses_input_item/1)
    Enum.each(body["output"], &assert_openresponses_output_item/1)
    Enum.each(body["tools"], &assert_openresponses_tool/1)
  end

  defp assert_openresponses_input_item(%{"type" => "message"} = item) do
    assert is_binary(item["id"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
    assert item["role"] in ["system", "developer", "user", "assistant", "tool"]
    assert is_list(item["content"])

    Enum.each(item["content"], fn
      %{"type" => "input_text"} = part ->
        assert is_binary(part["text"])

      %{"type" => "output_text"} = part ->
        assert is_binary(part["text"])
        assert is_list(part["annotations"])

      %{"type" => type} ->
        assert type in ["input_image", "input_file", "input_video", "refusal"]
    end)
  end

  defp assert_openresponses_input_item(%{"type" => "function_call"} = item) do
    assert_openresponses_output_item(item)
  end

  defp assert_openresponses_input_item(%{"type" => "function_call_output"} = item) do
    assert is_binary(item["id"])
    assert is_binary(item["call_id"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
    assert is_binary(item["output"]) or is_list(item["output"])
  end

  defp assert_openresponses_input_item(item),
    do: flunk("unexpected OpenResponses input item: #{inspect(item)}")

  defp assert_openresponses_output_item(%{"type" => "message"} = item) do
    assert is_binary(item["id"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
    assert item["role"] in ["system", "developer", "user", "assistant", "tool"]
    assert is_list(item["content"])
    assert is_nil(item["phase"]) or item["phase"] in ["commentary", "final_answer"]

    Enum.each(item["content"], fn
      %{"type" => "output_text"} = part ->
        assert is_binary(part["text"])
        assert is_list(part["annotations"])

      %{"type" => type} ->
        assert type in [
                 "input_text",
                 "text",
                 "input_image",
                 "input_file",
                 "input_video",
                 "refusal"
               ]
    end)
  end

  defp assert_openresponses_output_item(%{"type" => "function_call"} = item) do
    assert is_binary(item["id"])
    assert is_binary(item["call_id"])
    assert is_binary(item["name"])
    assert is_binary(item["arguments"])
    assert item["status"] in ["in_progress", "completed", "incomplete"]
  end

  defp assert_openresponses_output_item(item),
    do: flunk("unexpected OpenResponses output item: #{inspect(item)}")

  defp assert_openresponses_tool(%{"type" => "function"} = tool) do
    assert is_binary(tool["name"])
    assert is_nil(tool["description"]) or is_binary(tool["description"])
    assert is_nil(tool["parameters"]) or is_map(tool["parameters"])
    assert is_nil(tool["strict"]) or is_boolean(tool["strict"])
  end

  defp assert_openresponses_tool(tool),
    do: flunk("unexpected OpenResponses tool: #{inspect(tool)}")

  defp assert_response_usage(usage) do
    assert is_map(usage)
    assert is_integer(usage["input_tokens"])
    assert is_integer(usage["output_tokens"])
    assert is_integer(usage["total_tokens"])
    assert is_integer(get_in(usage, ["input_tokens_details", "cached_tokens"]))
    assert is_integer(get_in(usage, ["output_tokens_details", "reasoning_tokens"]))
  end

  @doc "Returns a minimal normalized Responses usage block for fixtures."
  def response_usage_fixture do
    %{
      "input_tokens" => 1,
      "output_tokens" => 2,
      "total_tokens" => 3,
      "input_tokens_details" => %{"cached_tokens" => 0},
      "output_tokens_details" => %{"reasoning_tokens" => 0}
    }
  end
end
