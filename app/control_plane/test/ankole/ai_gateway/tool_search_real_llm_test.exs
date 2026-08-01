defmodule Ankole.AIGateway.ToolSearchRealLLMTest do
  @moduledoc """
  Real-provider verification of self-implemented tool search and PTC.

  Run with `ANKOLE_REAL_LLM_E2E=1 mix test --only real_llm`. The tests speak
  the official wire dialect as a stateless client: deferred tools with
  `defer_loading`, `allowed_callers` program bindings, and history replay of
  the public items AIGateway produced in the previous response.
  """

  use Ankole.AIGatewayCase

  @moduletag :real_llm
  @moduletag timeout: 300_000

  @model System.get_env("ANKOLE_REAL_LLM_MODEL", "openai/gpt-5.5")

  setup do
    %{principal: agent} = agent_fixture()

    api_key = System.get_env("OPEN_ROUTER_API_KEY")

    if api_key in [nil, ""] do
      raise "OPEN_ROUTER_API_KEY is required for real_llm tool search tests"
    end

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "openrouter-real",
        provider_kind: "openrouter",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => api_key}]}
      })

    {:ok, _profile} =
      ModelProfiles.put_model_profile(agent.uid, "primary", %{
        provider_id: "openrouter-real",
        model: @model
      })

    %{agent: agent}
  end

  defp stream!(agent, request) do
    {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
    collect_events(stream, [])
  end

  # The stream may push its terminal batch and stop without waiting for more
  # demand, so a failed read drains the mailbox before giving up.
  defp collect_events(stream, events) do
    case AIGateway.read_response_stream(stream, 1) do
      :ok -> await_batch(stream, events, 180_000)
      {:error, _reason} -> await_batch(stream, events, 1_000)
    end
  end

  defp await_batch(stream, events, timeout) do
    receive do
      {:ai_gateway_response_stream, _ref, :events, batch, :continue} ->
        collect_events(stream, events ++ batch)

      {:ai_gateway_response_stream, _ref, :events, batch, {:terminal, outcome}} ->
        {events ++ batch, outcome}
    after
      timeout -> raise "real LLM stream ended without a terminal event"
    end
  end

  defp decoy_tools do
    for index <- 1..24 do
      %{
        "type" => "function",
        "name" => "dt_metric_#{index}",
        "description" => "Internal telemetry metric ##{index} for cluster dashboards",
        "defer_loading" => true,
        "parameters" => %{
          "type" => "object",
          "properties" => %{"window" => %{"type" => "string"}}
        }
      }
    end
  end

  defp stock_tool do
    %{
      "type" => "function",
      "name" => "bx_stock_price",
      "description" => "查询A股股票最新价格。Look up the latest A-share stock price by symbol.",
      "defer_loading" => true,
      "parameters" => %{
        "type" => "object",
        "properties" => %{"symbol" => %{"type" => "string", "description" => "六位股票代码"}},
        "required" => ["symbol"]
      }
    }
  end

  defp item_types(items), do: Enum.map(items, & &1["type"])

  defp program_output(call, output) do
    %{
      "type" =>
        if(call["type"] == "custom_tool_call",
          do: "custom_tool_call_output",
          else: "function_call_output"
        ),
      "call_id" => call["call_id"],
      "output" => output,
      "caller" => call["caller"]
    }
  end

  test "server-mode search loads the relevant deferred tool and completes with its result", %{
    agent: agent
  } do
    tools = [stock_tool() | decoy_tools()]

    request = %{
      "model" => "primary",
      "stream" => true,
      "tools" => tools,
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" => "查询贵州茅台(600519)的最新股价。先用 tool_search 找到合适的工具再调用它。"
            }
          ]
        }
      ]
    }

    {_events, outcome} = stream!(agent, request)
    assert outcome.terminal_error == nil

    types = item_types(outcome.public_items)
    assert "tool_search_call" in types
    assert "tool_search_output" in types

    [search_output] =
      Enum.filter(outcome.public_items, &(&1["type"] == "tool_search_output"))

    loaded_names = Enum.map(search_output["tools"], & &1["name"])
    assert "bx_stock_price" in loaded_names
    assert length(loaded_names) < 6

    [stock_call] =
      Enum.filter(outcome.public_items, &(&1["name"] == "bx_stock_price"))

    assert stock_call["type"] == "function_call"
    arguments = Ankole.JSON.decode!(stock_call["arguments"])
    assert arguments["symbol"] =~ "600519"

    # Second turn: answer the loaded tool call the way a stateless client does.
    follow_up = %{
      request
      | "input" =>
          request["input"] ++
            outcome.public_items ++
            [
              %{
                "type" => "function_call_output",
                "call_id" => stock_call["call_id"],
                "output" => ~s({"symbol":"600519","price":1712.5,"currency":"CNY"})
              }
            ]
    }

    {_events, final} = stream!(agent, follow_up)
    assert final.terminal_error == nil

    final_text =
      final.public_items
      |> Enum.filter(&(&1["type"] == "message"))
      |> Enum.flat_map(&(&1["content"] || []))
      |> Enum.map(&(&1["text"] || ""))
      |> Enum.join(" ")

    assert final_text =~ "1712"
  end

  test "client-mode search loads a tool across two client pauses", %{agent: agent} do
    request = %{
      "model" => "primary",
      "stream" => true,
      "tools" => [
        %{
          "type" => "tool_search",
          "execution" => "client",
          "description" => "Search the client tool catalog for a named finance capability."
        }
      ],
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" =>
                "First use tool_search to find the finance quote tool. Then call the loaded " <>
                  "tool for symbol 600519 and report its numeric price."
            }
          ]
        }
      ]
    }

    {_events, first} = stream!(agent, request)
    assert first.terminal_error == nil

    [search_call] = Enum.filter(first.public_items, &(&1["type"] == "tool_search_call"))
    assert search_call["execution"] == "client"
    assert is_binary(search_call["call_id"])

    finance_namespace = %{
      "type" => "namespace",
      "name" => "mcp__finance",
      "description" => "Financial data tools.",
      "tools" => [
        %{
          "type" => "function",
          "name" => "get_quote",
          "description" => "Return the latest numeric price for one stock symbol.",
          "defer_loading" => true,
          "parameters" => %{
            "type" => "object",
            "properties" => %{"symbol" => %{"type" => "string"}},
            "required" => ["symbol"],
            "additionalProperties" => false
          }
        }
      ]
    }

    search_output = %{
      "type" => "tool_search_output",
      "call_id" => search_call["call_id"],
      "status" => "completed",
      "execution" => "client",
      "tools" => [finance_namespace]
    }

    first_input = request["input"] ++ first.public_items ++ [search_output]
    {_events, second} = stream!(agent, %{request | "input" => first_input})
    assert second.terminal_error == nil

    quote_calls =
      Enum.filter(second.public_items, fn item ->
        item["type"] == "function_call" and item["name"] == "get_quote"
      end)

    assert length(quote_calls) == 1,
           "expected one quote call, got: #{inspect(second.public_items)}"

    quote_call = hd(quote_calls)

    assert quote_call["namespace"] == "mcp__finance"
    assert Ankole.JSON.decode!(quote_call["arguments"])["symbol"] =~ "600519"

    second_input =
      first_input ++
        second.public_items ++
        [
          %{
            "type" => "function_call_output",
            "call_id" => quote_call["call_id"],
            "output" => ~s({"symbol":"600519","price":1712.5})
          }
        ]

    {_events, final} = stream!(agent, %{request | "input" => second_input})
    assert final.terminal_error == nil

    final_text =
      final.public_items
      |> Enum.filter(&(&1["type"] == "message"))
      |> Enum.flat_map(&(&1["content"] || []))
      |> Enum.map(&(&1["text"] || ""))
      |> Enum.join(" ")

    assert final_text =~ "1712"
  end

  test "direct custom tool preserves raw text across stateless replay", %{agent: agent} do
    request = %{
      "model" => "primary",
      "stream" => true,
      "tools" => [
        %{
          "type" => "custom",
          "name" => "uppercase_text",
          "description" => "Return the raw input text in uppercase.",
          "format" => %{"type" => "text"}
        }
      ],
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" =>
                "Call uppercase_text exactly once with raw input ankole, then report its result."
            }
          ]
        }
      ]
    }

    {_events, first} = stream!(agent, request)
    assert first.terminal_error == nil

    [call] = Enum.filter(first.public_items, &(&1["type"] == "custom_tool_call"))
    assert call["name"] == "uppercase_text"
    assert call["input"] == "ankole"

    follow_up = %{
      request
      | "input" =>
          request["input"] ++
            first.public_items ++
            [
              %{
                "type" => "custom_tool_call_output",
                "call_id" => call["call_id"],
                "output" => "ANKOLE"
              }
            ]
    }

    {_events, final} = stream!(agent, follow_up)
    assert final.terminal_error == nil

    final_text =
      final.public_items
      |> Enum.filter(&(&1["type"] == "message"))
      |> Enum.flat_map(&(&1["content"] || []))
      |> Enum.map(&(&1["text"] || ""))
      |> Enum.join(" ")

    assert final_text =~ "ANKOLE"
  end

  test "PTC runs a program with parallel nested calls across pause and resume", %{agent: agent} do
    price_tool = %{
      "type" => "function",
      "name" => "get_price",
      "description" => "Returns an object with the latest numeric price for one stock symbol.",
      "allowed_callers" => ["programmatic"],
      "parameters" => %{
        "type" => "object",
        "properties" => %{"symbol" => %{"type" => "string"}},
        "required" => ["symbol"]
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"price" => %{"type" => "number"}},
        "required" => ["price"],
        "additionalProperties" => false
      }
    }

    request = %{
      "model" => "primary",
      "stream" => true,
      "tools" => [price_tool, %{"type" => "programmatic_tool_calling"}],
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" =>
                "用 program 工具写一段 JavaScript:用 Promise.all 并行调用 " <>
                  "tools.get_price({symbol:\"600519\"}) 和 tools.get_price({symbol:\"000001\"})," <>
                  "把两个返回值的 price 相加,用 text(总和) 输出。必须一次 program 调用完成,不要直接调用 get_price。"
            }
          ]
        }
      ]
    }

    {_events, outcome} = stream!(agent, request)
    assert outcome.terminal_error == nil

    types = item_types(outcome.public_items)
    assert "program" in types

    nested =
      Enum.filter(outcome.public_items, fn item ->
        item["type"] == "function_call" and is_map(item["caller"])
      end)

    assert length(nested) == 2
    [program_item] = Enum.filter(outcome.public_items, &(&1["type"] == "program"))
    assert Enum.all?(nested, &(&1["caller"]["caller_id"] == program_item["call_id"]))

    outputs =
      Enum.map(nested, fn call ->
        arguments = Ankole.JSON.decode!(call["arguments"])

        price =
          case arguments["symbol"] do
            "600519" -> 1700
            _other -> 300
          end

        %{
          "type" => "function_call_output",
          "call_id" => call["call_id"],
          "output" => Ankole.JSON.encode!(%{"price" => price}),
          "caller" => call["caller"]
        }
      end)

    follow_up = %{request | "input" => request["input"] ++ outcome.public_items ++ outputs}

    {_events, final} = stream!(agent, follow_up)
    assert final.terminal_error == nil

    final_types = item_types(final.public_items)
    assert "program_output" in final_types

    program_outputs = Enum.filter(final.public_items, &(&1["type"] == "program_output"))

    assert Enum.uniq_by(program_outputs, & &1["call_id"]) == program_outputs

    program_output =
      Enum.find(program_outputs, &(&1["call_id"] == program_item["call_id"])) ||
        flunk("the resumed program did not produce its matching output")

    assert program_output["status"] == "completed"

    assert program_output["result"] == "2000"
  end

  test "PTC replays dependent calls across two pauses", %{agent: agent} do
    seed_tool = %{
      "type" => "function",
      "name" => "get_seed",
      "description" => "Return an object with next_key (string) for one key.",
      "allowed_callers" => ["programmatic"],
      "parameters" => %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string"}},
        "required" => ["key"],
        "additionalProperties" => false
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"next_key" => %{"type" => "string"}},
        "required" => ["next_key"],
        "additionalProperties" => false
      }
    }

    value_tool = %{
      "type" => "function",
      "name" => "get_value",
      "description" => "Return an object with value (number) for one key.",
      "allowed_callers" => ["programmatic"],
      "parameters" => %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string"}},
        "required" => ["key"],
        "additionalProperties" => false
      },
      "output_schema" => %{
        "type" => "object",
        "properties" => %{"value" => %{"type" => "number"}},
        "required" => ["value"],
        "additionalProperties" => false
      }
    }

    request = %{
      "model" => "primary",
      "stream" => true,
      "tools" => [seed_tool, value_tool, %{"type" => "programmatic_tool_calling"}],
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" =>
                "Use exactly one program. First await tools.get_seed({key:\"root\"}). " <>
                  "Then await tools.get_value({key: seed.next_key}). Emit only the numeric value " <>
                  "with text(String(result.value)). Do not call either function directly."
            }
          ]
        }
      ]
    }

    {_events, first} = stream!(agent, request)
    assert first.terminal_error == nil

    [seed_call] =
      Enum.filter(first.public_items, fn item ->
        item["type"] == "function_call" and item["name"] == "get_seed"
      end)

    first_input =
      request["input"] ++
        first.public_items ++ [program_output(seed_call, ~s({"next_key":"leaf"}))]

    {_events, second} = stream!(agent, %{request | "input" => first_input})
    assert second.terminal_error == nil

    [value_call] =
      Enum.filter(second.public_items, fn item ->
        item["type"] == "function_call" and item["name"] == "get_value"
      end)

    assert Ankole.JSON.decode!(value_call["arguments"]) == %{"key" => "leaf"}

    second_input =
      first_input ++ second.public_items ++ [program_output(value_call, ~s({"value":73}))]

    {_events, final} = stream!(agent, %{request | "input" => second_input})
    assert final.terminal_error == nil

    [output] = Enum.filter(final.public_items, &(&1["type"] == "program_output"))
    assert output["status"] == "completed"
    assert output["result"] == "73"
  end

  test "PTC preserves custom tool text input and output", %{agent: agent} do
    request = %{
      "model" => "primary",
      "stream" => true,
      "tools" => [
        %{
          "type" => "custom",
          "name" => "reverse_text",
          "description" => "Return the input text with its characters reversed.",
          "format" => %{"type" => "text"},
          "allowed_callers" => ["programmatic"]
        },
        %{"type" => "programmatic_tool_calling"}
      ],
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            %{
              "type" => "input_text",
              "text" =>
                "Use exactly one program that awaits tools.reverse_text(\"ankole\") and emits " <>
                  "the returned string with text(result). Do not call reverse_text directly."
            }
          ]
        }
      ]
    }

    {_events, first} = stream!(agent, request)
    assert first.terminal_error == nil

    [call] = Enum.filter(first.public_items, &(&1["type"] == "custom_tool_call"))
    assert call["name"] == "reverse_text"
    assert call["input"] == "ankole"

    follow_up = %{
      request
      | "input" => request["input"] ++ first.public_items ++ [program_output(call, "elokna")]
    }

    {_events, final} = stream!(agent, follow_up)
    assert final.terminal_error == nil

    [output] = Enum.filter(final.public_items, &(&1["type"] == "program_output"))
    assert output["status"] == "completed"
    assert output["result"] == "elokna"
  end
end
