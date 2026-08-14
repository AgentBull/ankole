defmodule Ankole.AIGateway.ToolSearchTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ProgrammaticToolCalling, as: PTC
  alias Ankole.AIGateway.ToolSearch
  alias Ankole.AIGateway.ToolSearch.Index
  alias Ankole.AIGateway.ToolSearch.StreamLoop

  # Golden wire sample from codex rust-v0.147.0
  # codex-rs/protocol/src/models.rs `tool_search_call_roundtrips`.
  @codex_tool_search_call %{
    "type" => "tool_search_call",
    "call_id" => "search-1",
    "execution" => "client",
    "arguments" => %{"query" => "calendar create", "limit" => 1}
  }

  defp deferred_tool(name, description) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "defer_loading" => true,
      "parameters" => %{
        "type" => "object",
        "properties" => %{"symbol" => %{"type" => "string"}},
        "required" => ["symbol"]
      }
    }
  end

  defp base_request(tools, input \\ []) do
    %{"model" => "gpt-5.6", "tools" => tools, "input" => input}
  end

  defp client_search_output(call_id, tools \\ [], extra \\ %{}) do
    Map.merge(
      %{
        "type" => "tool_search_output",
        "call_id" => call_id,
        "status" => "completed",
        "execution" => "client",
        "tools" => tools
      },
      extra
    )
  end

  describe "plan/1" do
    test "passes through requests without tool search or deferred tools" do
      request = base_request([%{"type" => "function", "name" => "get_weather"}])

      assert {:ok, ^request, nil} = ToolSearch.plan(request)
    end

    test "passes through requests without any tools" do
      request = %{"model" => "gpt-5.6", "input" => "hello"}

      assert {:ok, ^request, nil} = ToolSearch.plan(request)
    end

    test "infers server mode from declared deferred tools" do
      request =
        base_request([
          %{"type" => "function", "name" => "get_weather", "description" => "Weather lookup"},
          deferred_tool("bx_market_data", "A股行情数据查询"),
          deferred_tool("bx_dragon_tiger", "龙虎榜席位数据")
        ])

      assert {:ok, provider_request, plan} = ToolSearch.plan(request)
      assert plan.execution == :server
      assert plan.tool_name == "tool_search"
      assert Enum.map(plan.catalog, & &1["name"]) == ["bx_market_data", "bx_dragon_tiger"]

      tool_names = Enum.map(provider_request["tools"], & &1["name"])
      assert tool_names == ["get_weather", "tool_search"]

      [search_tool] = Enum.filter(provider_request["tools"], &(&1["name"] == "tool_search"))
      assert search_tool["type"] == "function"
      assert search_tool["description"] =~ "bx_market_data"
      assert search_tool["description"] =~ "龙虎榜席位数据"
      assert search_tool["parameters"]["required"] == ["paths"]
      assert search_tool["parameters"]["properties"]["paths"]["type"] == "array"
    end

    test "plans deferred tools inside the responses-lite carrier" do
      additional_tools = %{
        "type" => "additional_tools",
        "role" => "developer",
        "tools" => [
          %{"type" => "function", "name" => "get_weather", "description" => "Weather lookup"},
          deferred_tool("bx_market_data", "A股行情数据查询"),
          %{"type" => "programmatic_tool_calling"}
        ]
      }

      request = %{
        "model" => "gpt-5.6",
        "tools" => nil,
        "input" => [
          additional_tools,
          %{"type" => "message", "role" => "developer", "content" => "Base instructions"},
          %{"type" => "message", "role" => "user", "content" => "查行情"}
        ]
      }

      assert {:ok, provider_request, plan} = ToolSearch.plan(request)
      assert plan.execution == :server
      assert provider_request["tools"] == nil

      [carrier | remaining_input] = provider_request["input"]
      assert carrier["type"] == "additional_tools"

      assert Enum.map(carrier["tools"], & &1["name"]) == [
               "get_weather",
               "tool_search",
               "program"
             ]

      assert Enum.at(remaining_input, 0)["role"] == "developer"

      assert {:ok, [loaded]} = ToolSearch.search_paths(plan, ["bx_market_data"])

      assert {:ok, _plan, next_tools} =
               ToolSearch.load_tools(plan, carrier["tools"], [loaded])

      continuation = ToolSearch.put_tools(provider_request, next_tools)

      assert continuation["tools"] == nil

      assert Enum.map(hd(continuation["input"])["tools"], & &1["name"]) == [
               "get_weather",
               "tool_search",
               "bx_market_data",
               "program"
             ]
    end

    test "infers client mode from a declaration without deferred tools" do
      declaration = %{
        "type" => "tool_search",
        "description" => "Search over MCP servers: bullx_financial_data"
      }

      request = base_request([declaration])

      assert {:ok, provider_request, plan} = ToolSearch.plan(request)
      assert plan.execution == :client
      assert plan.catalog == []

      [search_tool] = provider_request["tools"]
      assert search_tool["type"] == "function"
      assert search_tool["name"] == "tool_search"
      assert search_tool["description"] == "Search over MCP servers: bullx_financial_data"
    end

    test "honors an explicit execution declaration" do
      request =
        base_request([
          %{"type" => "tool_search", "execution" => "client"},
          deferred_tool("bx_market_data", "行情")
        ])

      assert {:ok, _provider_request, plan} = ToolSearch.plan(request)
      assert plan.execution == :client
    end

    test "rejects duplicate tool_search declarations" do
      request = base_request([%{"type" => "tool_search"}, %{"type" => "tool_search"}])

      assert {:error, {:invalid_tool_search, :duplicate_declaration}} = ToolSearch.plan(request)
    end

    test "rejects malformed namespaces" do
      request =
        base_request([%{"type" => "namespace", "name" => "agents", "defer_loading" => true}])

      assert {:error, {:invalid_tool_contract, {:namespace_tools_must_be_a_list, "agents", nil}}} =
               ToolSearch.plan(request)
    end

    test "keeps namespace children native across search and provider rounds" do
      namespace = %{
        "type" => "namespace",
        "name" => "mcp__finance",
        "description" => "Financial data tools.",
        "tools" => [
          deferred_tool("stock_price", "查询股票行情"),
          deferred_tool("company_news", "查询公司新闻")
        ]
      }

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request(
                   [namespace, %{"type" => "tool_search"}],
                   [%{"type" => "message", "role" => "user", "content" => "股票行情"}]
                 )
               )

      assert Enum.map(plan.catalog, & &1["name"]) == [
               "stock_price",
               "company_news"
             ]

      assert Enum.map(provider_request["tools"], & &1["name"]) == ["tool_search"]
      assert hd(provider_request["tools"])["description"] =~ "mcp__finance"
      refute hd(provider_request["tools"])["description"] =~ "stock_price"

      assert {:ok, [loaded]} = ToolSearch.search_paths(plan, ["mcp__finance"])
      assert loaded["namespace"] == "mcp__finance"
      assert loaded["name"] == "stock_price"

      output =
        ToolSearch.public_search_output(
          plan,
          %{"id" => "fc_search", "call_id" => "call_search"},
          [loaded]
        )

      assert [
               %{
                 "type" => "namespace",
                 "name" => "mcp__finance",
                 "tools" => [
                   %{
                     "type" => "function",
                     "name" => "stock_price",
                     "defer_loading" => true
                   }
                 ]
               }
             ] = output["tools"]

      assert {:ok, _plan, provider_tools} =
               ToolSearch.load_tools(plan, provider_request["tools"], [loaded])

      loaded_provider = Enum.find(provider_tools, &(&1["type"] == "namespace"))
      assert loaded_provider["name"] == "mcp__finance"
      assert [%{"name" => "stock_price"} = child] = loaded_provider["tools"]
      refute Map.has_key?(child, "defer_loading")
    end

    test "keeps namespaced custom tool history native for Responses replay" do
      namespace = %{
        "type" => "namespace",
        "name" => "functions",
        "description" => "Functions.",
        "tools" => [
          %{
            "type" => "custom",
            "name" => "exec",
            "description" => "Run one tool program.",
            "format" => %{"type" => "text"}
          }
        ]
      }

      request =
        base_request([namespace], [
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_exec",
            "namespace" => "functions",
            "name" => "exec",
            "input" => "return await tools.shell()"
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_exec",
            "output" => "ok"
          }
        ])

      assert {:ok, provider_request, nil} = ToolSearch.plan(request)

      assert [%{"type" => "namespace", "name" => "functions"} = provider_namespace] =
               provider_request["tools"]

      assert [%{"type" => "custom", "name" => "exec"}] = provider_namespace["tools"]

      [provider_call, provider_output] = provider_request["input"]
      assert provider_call["type"] == "custom_tool_call"
      assert provider_call["namespace"] == "functions"
      assert provider_call["name"] == "exec"
      assert provider_output["type"] == "custom_tool_call_output"
      assert provider_output["call_id"] == provider_call["call_id"]
    end

    test "passes namespaced custom tool history through an empty Responses Lite carrier" do
      request = %{
        "model" => "gpt-5.6",
        "tools" => nil,
        "input" => [
          %{"type" => "additional_tools", "role" => "developer", "tools" => []},
          %{
            "type" => "custom_tool_call",
            "call_id" => "call_apply_patch",
            "namespace" => "functions",
            "name" => "apply_patch",
            "input" => "*** Begin Patch"
          },
          %{
            "type" => "custom_tool_call_output",
            "call_id" => "call_apply_patch",
            "output" => "Done!"
          }
        ]
      }

      assert {:ok, provider_request, nil} = ToolSearch.plan(request)

      [carrier, provider_call, provider_output] = provider_request["input"]
      assert carrier["tools"] == []
      assert provider_request["tools"] == nil
      assert provider_call["type"] == "custom_tool_call"
      assert provider_call["namespace"] == "functions"
      assert provider_call["name"] == "apply_patch"
      assert provider_output["call_id"] == provider_call["call_id"]
    end

    test "passes namespaced function history through without current tools" do
      request = %{
        "model" => "gpt-5.6",
        "input" => [
          %{
            "type" => "function_call",
            "call_id" => "call_shell",
            "namespace" => "functions",
            "name" => "shell",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call_shell",
            "output" => "ok"
          }
        ]
      }

      assert {:ok, provider_request, nil} = ToolSearch.plan(request)

      [provider_call, provider_output] = provider_request["input"]
      assert provider_call["type"] == "function_call"
      assert provider_call["namespace"] == "functions"
      assert provider_call["name"] == "shell"
      assert provider_output["call_id"] == provider_call["call_id"]
    end

    test "rejects a base tool colliding with the search tool name" do
      request =
        base_request([
          %{"type" => "function", "name" => "tool_search"},
          deferred_tool("bx_market_data", "行情")
        ])

      assert {:error, {:invalid_tool_contract, {:reserved_tool_name, "tool_search"}}} =
               ToolSearch.plan(request)
    end

    test "zero built-in budget removes native and synthesized tools before the first round" do
      request =
        base_request([
          %{"type" => "web_search"},
          %{"type" => "web_search_2025_08_26"},
          %{"type" => "web_search_preview_2025_03_11"},
          %{"type" => "function", "name" => "get_weather"},
          %{"type" => "tool_search", "execution" => "client"},
          %{"type" => "programmatic_tool_calling"}
        ])
        |> Map.put("max_tool_calls", 0)
        |> Map.put("tool_choice", %{"type" => "web_search_2025_08_26"})

      assert {:ok, provider_request, plan} = ToolSearch.plan(request)

      provider_request = StreamLoop.apply_tool_budget(plan, provider_request, 0)

      assert [%{"type" => "function", "name" => "get_weather"}] =
               ToolSearch.list_tools(provider_request)

      refute Map.has_key?(provider_request, "max_tool_calls")
      assert provider_request["tool_choice"] == "auto"
    end

    test "zero budget removes versioned built-ins from an allowed tool choice" do
      request = %{
        "input" => "hello",
        "tools" => [
          %{"type" => "function", "name" => "get_weather"},
          %{"type" => "computer"},
          %{"type" => "mcp", "server_label" => "inventory"},
          %{"type" => "web_search_2025_08_26"},
          %{"type" => "web_search_preview_2025_03_11"}
        ],
        "tool_choice" => %{
          "type" => "allowed_tools",
          "mode" => "auto",
          "tools" => [
            %{"type" => "function", "name" => "get_weather"},
            %{"type" => "computer_use"},
            %{"type" => "mcp", "server_label" => "inventory", "name" => "lookup"},
            %{"type" => "web_search_2025_08_26"},
            %{"type" => "web_search_preview_2025_03_11"}
          ]
        }
      }

      provider_request = StreamLoop.disable_budgeted_effects(nil, request)

      assert ToolSearch.list_tools(provider_request) == [
               %{"type" => "function", "name" => "get_weather"}
             ]

      assert provider_request["tool_choice"] == %{
               "type" => "allowed_tools",
               "mode" => "auto",
               "tools" => [%{"type" => "function", "name" => "get_weather"}]
             }
    end

    test "zero budget clears the computer tool-choice alias" do
      request = %{
        "input" => "hello",
        "tools" => [
          %{"type" => "function", "name" => "get_weather"},
          %{"type" => "computer"}
        ],
        "tool_choice" => %{"type" => "computer_use"}
      }

      provider_request = StreamLoop.disable_budgeted_effects(nil, request)

      assert ToolSearch.list_tools(provider_request) == [
               %{"type" => "function", "name" => "get_weather"}
             ]

      assert provider_request["tool_choice"] == "auto"
    end

    test "zero budget clears an exact MCP tool choice that includes a name" do
      request = %{
        "input" => "hello",
        "tools" => [
          %{"type" => "function", "name" => "get_weather"},
          %{"type" => "mcp", "server_label" => "inventory"}
        ],
        "tool_choice" => %{
          "type" => "mcp",
          "server_label" => "inventory",
          "name" => "lookup"
        }
      }

      provider_request = StreamLoop.disable_budgeted_effects(nil, request)

      assert ToolSearch.list_tools(provider_request) == [
               %{"type" => "function", "name" => "get_weather"}
             ]

      assert provider_request["tool_choice"] == "auto"
    end

    test "rewrites a paired tool_search_call into a provider function call" do
      output = %{
        "type" => "tool_search_output",
        "call_id" => "search-1",
        "status" => "completed",
        "execution" => "client",
        "tools" => []
      }

      request =
        base_request(
          [%{"type" => "tool_search", "execution" => "client"}],
          [@codex_tool_search_call, output]
        )

      assert {:ok, provider_request, _plan} = ToolSearch.plan(request)

      [call, _output] = provider_request["input"]
      assert call["type"] == "function_call"
      assert call["name"] == "tool_search"
      assert call["call_id"] == "search-1"

      assert Ankole.JSON.decode!(call["arguments"]) == %{
               "query" => "calendar create",
               "limit" => 1
             }
    end

    test "rewrites tool_search_output items and unions loaded tools" do
      loaded = deferred_tool("bx_market_data", "A股行情数据查询")

      output_item = %{
        "type" => "tool_search_output",
        "call_id" => "search-1",
        "status" => "completed",
        "execution" => "client",
        "tools" => [loaded]
      }

      request =
        base_request(
          [%{"type" => "tool_search", "execution" => "client"}],
          [
            %{"type" => "message", "role" => "user", "content" => "查行情"},
            @codex_tool_search_call,
            output_item
          ]
        )

      assert {:ok, provider_request, plan} = ToolSearch.plan(request)

      [_message, _call, output] = provider_request["input"]
      assert output["type"] == "function_call_output"
      assert output["call_id"] == "search-1"
      assert output["output"] =~ "bx_market_data"

      tool_names = Enum.map(provider_request["tools"], & &1["name"])
      assert "bx_market_data" in tool_names
      assert MapSet.member?(plan.loaded_identities, {nil, "bx_market_data"})

      [loaded_tool] = Enum.filter(provider_request["tools"], &(&1["name"] == "bx_market_data"))
      refute Map.has_key?(loaded_tool, "defer_loading")
    end

    test "replays Codex namespace search output without flattening namespaced calls" do
      loaded_namespace = %{
        "type" => "namespace",
        "name" => "mcp__calendar",
        "description" => "Calendar tools.",
        "tools" => [deferred_tool("create_event", "Create a calendar event")]
      }

      request =
        base_request(
          [%{"type" => "tool_search", "execution" => "client"}],
          [
            @codex_tool_search_call,
            %{
              "type" => "tool_search_output",
              "call_id" => "search-1",
              "status" => "completed",
              "execution" => "client",
              "tools" => [loaded_namespace]
            },
            %{
              "type" => "function_call",
              "call_id" => "calendar-1",
              "namespace" => "mcp__calendar",
              "name" => "create_event",
              "arguments" => ~s({"title":"Review"})
            }
          ]
        )

      assert {:ok, provider_request, plan} = ToolSearch.plan(request)

      [search_call, search_output, provider_call] = provider_request["input"]
      assert search_call["name"] == "tool_search"
      assert search_output["type"] == "function_call_output"
      assert provider_call["namespace"] == "mcp__calendar"
      assert provider_call["name"] == "create_event"
      assert %ToolSearch.Plan{} = plan
    end

    test "keeps loaded tools out of the searchable listing" do
      loaded = deferred_tool("bx_market_data", "A股行情数据查询")

      search_call = %{
        "type" => "tool_search_call",
        "call_id" => nil,
        "status" => "completed",
        "execution" => "server",
        "arguments" => %{"paths" => ["bx_market_data"]}
      }

      output_item = %{
        "type" => "tool_search_output",
        "call_id" => nil,
        "status" => "completed",
        "execution" => "server",
        "tools" => [loaded]
      }

      request =
        base_request(
          [deferred_tool("bx_market_data", "A股行情数据查询"), deferred_tool("bx_news", "新闻")],
          [search_call, output_item]
        )

      assert {:ok, provider_request, _plan} = ToolSearch.plan(request)

      [search_tool] = Enum.filter(provider_request["tools"], &(&1["name"] == "tool_search"))
      refute search_tool["description"] =~ "bx_market_data:"
      assert search_tool["description"] =~ "bx_news"
    end

    test "rejects managed history when its declaration is absent" do
      cases = [
        {%{"type" => "program", "call_id" => "prog"}, {:invalid_program, :declaration_missing}},
        {%{"type" => "program_output", "call_id" => "prog"},
         {:invalid_program, :declaration_missing}},
        {%{
           "type" => "tool_search_call",
           "call_id" => nil,
           "execution" => "server",
           "arguments" => %{"paths" => ["weather"]}
         }, {:invalid_tool_search_history, :declaration_missing}},
        {%{
           "type" => "function_call_output",
           "call_id" => "nested",
           "caller" => %{"type" => "program", "caller_id" => "prog"}
         }, {:invalid_program, :declaration_missing}}
      ]

      for {item, expected} <- cases do
        assert {:error, ^expected} = ToolSearch.plan(base_request([], [item]))
      end
    end

    test "keeps a client-loaded tool callable without another Tool Search declaration" do
      loaded = %{
        "type" => "function",
        "name" => "calendar",
        "description" => "Read the calendar.",
        "parameters" => %{"type" => "object"}
      }

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request(
                   [],
                   [
                     @codex_tool_search_call,
                     client_search_output("search-1", [loaded])
                   ]
                 )
               )

      assert plan.execution == nil
      assert plan.tool_name == nil
      assert plan.loaded_identities == MapSet.new([{nil, "calendar"}])

      assert Enum.map(provider_request["input"], & &1["type"]) == [
               "function_call",
               "function_call_output"
             ]

      assert Enum.map(provider_request["tools"], & &1["name"]) == ["calendar"]
    end

    test "removes a client-loaded tool when the surviving output omits it" do
      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request(
                   [],
                   [@codex_tool_search_call, client_search_output("search-1", [])]
                 )
               )

      assert plan.loaded_identities == MapSet.new()
      assert provider_request["tools"] == []
    end

    test "keeps a prior-turn client-loaded tool callable when Tool Search remains declared" do
      loaded = %{
        "type" => "function",
        "name" => "prior_calendar",
        "description" => "Read the prior calendar.",
        "parameters" => %{"type" => "object"}
      }

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request(
                   [%{"type" => "tool_search", "execution" => "client"}],
                   [
                     @codex_tool_search_call,
                     client_search_output("search-1", [loaded]),
                     %{"role" => "user", "content" => "Start a new turn"}
                   ]
                 )
               )

      assert plan.execution == :client
      assert plan.loaded_identities == MapSet.new([{nil, "prior_calendar"}])

      assert Enum.map(provider_request["tools"], & &1["name"]) == [
               "prior_calendar",
               "tool_search"
             ]
    end

    test "accepts the same client tool when Codex reloads it in a later user turn" do
      loaded = %{
        "type" => "function",
        "name" => "calendar",
        "description" => "Read the calendar.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20}
          }
        }
      }

      second_search_call =
        @codex_tool_search_call
        |> Map.put("call_id", "search-2")
        |> put_in(["arguments", "query"], "calendar again")

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request(
                   [%{"type" => "tool_search", "execution" => "client"}],
                   [
                     %{"type" => "message", "role" => "user", "content" => "First turn"},
                     @codex_tool_search_call,
                     client_search_output("search-1", [loaded]),
                     %{"role" => "user", "content" => "Second turn"},
                     second_search_call,
                     client_search_output("search-2", [loaded])
                   ]
                 )
               )

      assert plan.loaded_identities == MapSet.new([{nil, "calendar"}])
      assert Enum.map(provider_request["tools"], & &1["name"]) == ["calendar", "tool_search"]

      [calendar] = Enum.filter(provider_request["tools"], &(&1["name"] == "calendar"))

      assert calendar["parameters"]["properties"]["limit"] == %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 20
             }
    end

    test "keeps client-loaded history callable beside current server Tool Search" do
      loaded = deferred_tool("calendar", "Read the calendar")

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request(
                   [loaded],
                   [
                     @codex_tool_search_call,
                     client_search_output("search-1", [loaded]),
                     %{"role" => "user", "content" => "Start a server-owned turn"}
                   ]
                 )
               )

      assert plan.execution == :server
      assert plan.loaded_identities == MapSet.new([{nil, "calendar"}])
      assert Enum.map(provider_request["tools"], & &1["name"]) == ["calendar", "tool_search"]

      search_tool = Enum.find(provider_request["tools"], &(&1["name"] == "tool_search"))
      refute search_tool["description"] =~ "calendar:"
    end

    test "replays a complete server search pair after its tool leaves the current catalog" do
      loaded_namespace = %{
        "type" => "namespace",
        "name" => "mcp__retired_server",
        "description" => "A removed server's historical tools.",
        "tools" => [
          %{
            "type" => "function",
            "name" => "render_report",
            "description" => "Render a historical report.",
            "defer_loading" => true,
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "width" => %{"type" => "integer", "minimum" => 1, "maximum" => 4_096}
              }
            }
          }
        ]
      }

      search_call = %{
        "type" => "tool_search_call",
        "call_id" => nil,
        "status" => "completed",
        "execution" => "server",
        "arguments" => %{"paths" => ["mcp__retired_server"]}
      }

      search_output = %{
        "type" => "tool_search_output",
        "call_id" => nil,
        "status" => "completed",
        "execution" => "server",
        "tools" => [loaded_namespace]
      }

      historical_call = %{
        "type" => "function_call",
        "call_id" => "retired-call",
        "namespace" => "mcp__retired_server",
        "name" => "render_report",
        "arguments" => ~s({"width":640})
      }

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request([], [
                   search_call,
                   search_output,
                   historical_call,
                   %{
                     "type" => "function_call_output",
                     "call_id" => "retired-call",
                     "output" => "historical result"
                   }
                 ])
               )

      assert plan.execution == nil
      assert plan.tool_name == nil
      assert plan.loaded_identities == MapSet.new()

      assert [provider_search_call, provider_search_output, provider_call, _provider_output] =
               provider_request["input"]

      assert provider_search_call["name"] == "tool_search"
      assert provider_search_output["call_id"] == provider_search_call["call_id"]
      assert provider_call["namespace"] == "mcp__retired_server"
      assert provider_call["name"] == "render_report"

      assert provider_request["tools"] == []

      historical_contract =
        Enum.find(
          plan.contracts,
          &({&1.namespace, &1.name} == {"mcp__retired_server", "render_report"})
        )

      assert historical_contract.parameters["properties"]["width"] == %{
               "type" => "integer",
               "minimum" => 1,
               "maximum" => 4_096
             }

      current_namespace = %{
        "type" => "namespace",
        "name" => "mcp__current_server",
        "tools" => [deferred_tool("lookup", "Look up current data")]
      }

      assert {:ok, current_provider_request, current_plan} =
               ToolSearch.plan(
                 base_request([current_namespace], [
                   search_call,
                   search_output,
                   historical_call,
                   %{
                     "type" => "function_call_output",
                     "call_id" => "retired-call",
                     "output" => "historical result"
                   }
                 ])
               )

      assert current_plan.execution == :server
      assert Enum.map(current_provider_request["tools"], & &1["name"]) == ["tool_search"]

      refute Enum.any?(current_provider_request["tools"], fn tool ->
               tool["name"] == "mcp__retired_server__render_report"
             end)
    end

    test "rejects malformed or conflicting client-loaded contracts atomically" do
      malformed_namespace = %{
        "type" => "namespace",
        "name" => "crm",
        "tools" => ["not-a-tool"]
      }

      assert {:error, {:invalid_tool_search_history, :namespace_children_must_be_objects}} =
               ToolSearch.plan(
                 base_request(
                   [],
                   [
                     @codex_tool_search_call,
                     client_search_output("search-1", [malformed_namespace])
                   ]
                 )
               )

      existing = %{
        "type" => "function",
        "name" => "calendar",
        "parameters" => %{"type" => "object"}
      }

      changed = put_in(existing, ["parameters", "type"], "array")

      assert {:error, {:invalid_tool_contract, {:loaded_tool_mismatch, "calendar"}}} =
               ToolSearch.plan(
                 base_request(
                   [existing],
                   [
                     @codex_tool_search_call,
                     client_search_output("search-1", [changed])
                   ]
                 )
               )

      assert {:error, {:invalid_tool_contract, {:reserved_tool_name, "program"}}} =
               ToolSearch.plan(
                 base_request(
                   [],
                   [
                     @codex_tool_search_call,
                     client_search_output("search-1", [
                       %{"type" => "function", "name" => "program"}
                     ])
                   ]
                 )
               )
    end

    test "requires strict client search pairs" do
      call = @codex_tool_search_call
      output = client_search_output("search-1")

      cases = [
        {[output], {:orphan_client_search_output, "search-1"}},
        {[call, client_search_output("search-2")],
         {:mismatched_client_search_output, "search-2"}},
        {[call, call], {:duplicate_client_search_call, "search-1"}},
        {[call, output, output], {:duplicate_client_search_output, "search-1"}},
        {[call], {:unanswered_client_search_call, "search-1"}},
        {[call, Map.delete(output, "status")], {:incomplete_tool_search_output, "search-1"}},
        {[call, Map.put(output, "status", "in_progress")],
         {:incomplete_tool_search_output, "search-1", "in_progress"}},
        {[call, Map.delete(output, "execution")], {:invalid_search_output_id, "search-1"}},
        {[call, Map.put(output, "call_id", nil)], {:invalid_tool_search_output, nil}}
      ]

      for {input, expected} <- cases do
        assert {:error, {:invalid_tool_search_history, ^expected}} =
                 ToolSearch.plan(
                   base_request([%{"type" => "tool_search", "execution" => "client"}], input)
                 )
      end
    end

    test "preserves a deferred custom contract through search and loading" do
      format = %{"type" => "grammar", "syntax" => "lark", "definition" => "start: WORD"}
      output_schema = %{"type" => "object", "required" => ["changed"]}

      custom = %{
        "type" => "custom",
        "name" => "apply_edit",
        "description" => "Apply an edit.",
        "format" => format,
        "output_schema" => output_schema,
        "allowed_callers" => ["direct", "programmatic"],
        "defer_loading" => true
      }

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request([
                   custom,
                   %{"type" => "tool_search", "execution" => "server"},
                   %{"type" => "programmatic_tool_calling"}
                 ])
               )

      assert {:ok, [loaded]} = ToolSearch.search_paths(plan, ["apply_edit"])
      assert loaded["format"] == format
      assert loaded["output_schema"] == output_schema
      refute Map.has_key?(loaded, "parameters")

      public =
        ToolSearch.public_search_output(
          plan,
          %{"id" => "fc_search", "call_id" => "call_search"},
          [loaded]
        )

      assert [
               %{
                 "type" => "namespace",
                 "name" => "functions",
                 "description" => "",
                 "tools" => [public_tool]
               }
             ] = public["tools"]

      assert public_tool["type"] == "custom"
      assert public_tool["format"] == format
      assert public_tool["output_schema"] == output_schema

      assert {:ok, loaded_plan, tools} =
               ToolSearch.load_tools(plan, provider_request["tools"], [loaded])

      provider_tool = Enum.find(tools, &(&1["name"] == "apply_edit"))
      assert provider_tool["type"] == "custom"
      assert provider_tool["format"] == format
      refute Map.has_key?(provider_tool, "output_schema")
      refute Map.has_key?(provider_tool, "parameters")
      assert Enum.any?(loaded_plan.ptc.program.bindings, &(&1.name == "apply_edit"))
    end

    test "rejects a complete loaded list when any member is invalid" do
      assert {:ok, provider_request, plan} =
               ToolSearch.plan(base_request([deferred_tool("quote", "Quote lookup")]))

      assert {:ok, [loaded]} = ToolSearch.search_paths(plan, ["quote"])
      invalid = %{"type" => "function", "name" => "broken", "allowed_callers" => []}

      assert {:error, {:invalid_tool_contract, {:invalid_allowed_callers, "broken", []}}} =
               ToolSearch.load_tools(plan, provider_request["tools"], [loaded, invalid])

      assert plan.loaded_identities == MapSet.new()
    end

    test "keeps root and namespace identities separate before terminal adapters" do
      request =
        base_request([
          %{"type" => "function", "name" => "a__b"},
          %{
            "type" => "namespace",
            "name" => "a",
            "tools" => [%{"type" => "function", "name" => "b"}]
          }
        ])

      assert {:ok, ^request, nil} = ToolSearch.plan(request)
    end

    test "rejects a program contract that exceeds the description budget" do
      huge_tool = %{
        "type" => "function",
        "name" => "huge",
        "description" => String.duplicate("x", 40_000),
        "parameters" => %{"type" => "object"},
        "allowed_callers" => ["programmatic"]
      }

      assert {:error, {:invalid_program, {:program_contract_too_large, bytes, 32_768}}} =
               ToolSearch.plan(
                 base_request([huge_tool, %{"type" => "programmatic_tool_calling"}])
               )

      assert bytes > 32_768
    end

    test "a dual-channel contract is referenced once instead of copied into program" do
      huge_tool = %{
        "type" => "function",
        "name" => "huge",
        "description" => String.duplicate("x", 40_000),
        "parameters" => %{"type" => "object"},
        "allowed_callers" => ["direct", "programmatic"]
      }

      assert {:ok, provider_request, plan} =
               ToolSearch.plan(
                 base_request([huge_tool, %{"type" => "programmatic_tool_calling"}])
               )

      program = PTC.provider_tool(plan.ptc)
      assert program["description"] =~ ~s|matching direct tool declarations: ["huge"]|
      refute program["description"] =~ String.duplicate("x", 1_000)

      assert Enum.any?(
               provider_request["tools"],
               &(&1["name"] == "huge" and byte_size(&1["description"]) == 40_000)
             )
    end

    test "rejects bindings that cannot fit the resumable fingerprint snapshot" do
      tools =
        for index <- 1..129 do
          %{
            "type" => "function",
            "name" => "t#{index}",
            "parameters" => %{"type" => "object"},
            "allowed_callers" => ["programmatic"]
          }
        end

      assert {:error,
              {:invalid_program,
               {:program_binding_snapshot_invalid, :invalid_program_fingerprint_bindings}}} =
               ToolSearch.plan(base_request(tools ++ [%{"type" => "programmatic_tool_calling"}]))
    end
  end

  describe "program history ordering" do
    setup do
      tool = %{
        "type" => "function",
        "name" => "worker",
        "parameters" => %{"type" => "object"},
        "allowed_callers" => ["programmatic"]
      }

      tools = [tool, %{"type" => "programmatic_tool_calling"}]
      assert {:ok, _request, plan} = ToolSearch.plan(base_request(tools))
      code = "await tools.worker({})"

      root = %{
        "type" => "program",
        "call_id" => "prog",
        "code" => code,
        "fingerprint" => PTC.fingerprint(code, plan.ptc.program.bindings),
        "status" => "completed"
      }

      caller = %{"type" => "program", "caller_id" => "prog"}

      call = %{
        "type" => "function_call",
        "call_id" => "nested",
        "name" => "worker",
        "arguments" => "{}",
        "status" => "completed",
        "caller" => caller
      }

      output = %{
        "type" => "function_call_output",
        "call_id" => "nested",
        "output" => "ok",
        "caller" => caller
      }

      program_output = %{
        "type" => "program_output",
        "call_id" => "prog",
        "status" => "completed",
        "result" => "done"
      }

      %{tools: tools, root: root, call: call, output: output, program_output: program_output}
    end

    test "validates program outputs and refuses to settle unanswered children", context do
      cases = [
        {[context.root, Map.delete(context.program_output, "status")],
         {:invalid_program_output, "prog"}},
        {[context.root, Map.delete(context.program_output, "result")],
         {:invalid_program_output, "prog"}},
        {[context.root, context.call, context.program_output],
         {:program_calls_unanswered, "prog"}}
      ]

      for {input, expected} <- cases do
        assert {:error, {:invalid_program, ^expected}} =
                 ToolSearch.plan(base_request(context.tools, input))
      end
    end

    test "rejects children after the owning program is closed", context do
      assert {:error, {:invalid_program, {:late_program_call, "prog", "nested"}}} =
               ToolSearch.plan(
                 base_request(context.tools, [context.root, context.program_output, context.call])
               )

      assert {:error, {:invalid_program, {:late_program_call_output, "prog", "nested"}}} =
               ToolSearch.plan(
                 base_request(context.tools, [
                   context.root,
                   context.program_output,
                   context.output
                 ])
               )
    end

    test "requires a nested output to match call type and name", context do
      custom_output = %{context.output | "type" => "custom_tool_call_output"}
      wrong_name = Map.put(context.output, "name", "other")

      assert {:error,
              {:invalid_program, {:invalid_program_call_output, "prog", "nested", :type_mismatch}}} =
               ToolSearch.plan(
                 base_request(context.tools, [context.root, context.call, custom_output])
               )

      assert {:error,
              {:invalid_program, {:invalid_program_call_output, "prog", "nested", :name_mismatch}}} =
               ToolSearch.plan(
                 base_request(context.tools, [context.root, context.call, wrong_name])
               )
    end
  end

  describe "hosted namespace resolution" do
    setup do
      catalog = [
        %{"type" => "function", "name" => "bx_market_data", "description" => "A股行情与K线数据查询"},
        %{"type" => "function", "name" => "bx_dragon_tiger", "description" => "龙虎榜席位与营业部数据"},
        %{
          "type" => "function",
          "name" => "get_weather",
          "description" => "Weather forecast lookup"
        }
      ]

      {:ok, plan} =
        case ToolSearch.plan(base_request(Enum.map(catalog, &Map.put(&1, "defer_loading", true)))) do
          {:ok, _request, plan} -> {:ok, plan}
        end

      %{plan: plan}
    end

    test "root paths resolve exactly", %{plan: plan} do
      assert {:ok, [%{"name" => "bx_dragon_tiger"} = tool]} =
               ToolSearch.search_paths(plan, ["bx_dragon_tiger"])

      assert tool["defer_loading"] == true
    end

    test "uses owner-supplied metadata only for bounded namespace ranking" do
      tool =
        deferred_tool("opaque_tool", "Generic lookup")
        |> Map.put(
          "__ankole_search_text",
          "raw-name canonical_name Market Title server.one initialize instructions security_id"
        )

      namespace = %{
        "type" => "namespace",
        "name" => "market",
        "description" => "Market tools",
        "tools" => [
          tool,
          deferred_tool("other_tool", "Weather forecast")
        ]
      }

      {:ok, provider_request, plan} =
        ToolSearch.plan(
          base_request(
            [namespace, %{"type" => "tool_search"}],
            [%{"type" => "message", "role" => "user", "content" => "lookup security_id"}]
          )
        )

      assert {:ok, [loaded]} = ToolSearch.search_paths(plan, ["market"])
      assert loaded["namespace"] == "market"
      assert loaded["name"] == "opaque_tool"

      output =
        ToolSearch.public_search_output(
          plan,
          %{"id" => "fc_search", "call_id" => "call_search"},
          [loaded]
        )

      [public_tool] = output["tools"]
      refute Map.has_key?(public_tool, "__ankole_search_text")

      assert {:ok, _plan, provider_tools} =
               ToolSearch.load_tools(plan, provider_request["tools"], [loaded])

      provider_namespace = Enum.find(provider_tools, &(&1["name"] == "market"))
      provider_tool = Enum.find(provider_namespace["tools"], &(&1["name"] == "opaque_tool"))
      refute Map.has_key?(provider_tool, "__ankole_search_text")
    end

    test "preserves an empty namespace description across a server load" do
      namespace = %{
        "type" => "namespace",
        "name" => "mcp__e2e_ptc",
        "description" => "",
        "tools" => [deferred_tool("lookup_ptc_marker", "Return one marker")]
      }

      {:ok, provider_request, plan} =
        ToolSearch.plan(base_request([namespace, %{"type" => "tool_search"}]))

      assert {:ok, [loaded]} = ToolSearch.search_paths(plan, ["mcp__e2e_ptc"])
      assert loaded["namespace_description"] == ""

      assert {:ok, _loaded_plan, provider_tools} =
               ToolSearch.load_tools(plan, provider_request["tools"], [loaded])

      assert Enum.any?(provider_tools, fn tool ->
               tool["type"] == "namespace" and tool["name"] == "mcp__e2e_ptc" and
                 Enum.any?(tool["tools"], &(&1["name"] == "lookup_ptc_marker"))
             end)

      output =
        ToolSearch.public_search_output(
          plan,
          %{"id" => "fc_search", "call_id" => "call_search"},
          [loaded]
        )

      assert [%{"name" => "mcp__e2e_ptc", "description" => ""}] = output["tools"]
    end
  end

  describe "public item shapes" do
    test "client mode search call keeps the codex golden shape" do
      {:ok, _request, plan} =
        ToolSearch.plan(base_request([%{"type" => "tool_search", "execution" => "client"}]))

      item = %{
        "type" => "function_call",
        "name" => "tool_search",
        "call_id" => "search-1",
        "arguments" => ~s({"query":"calendar create","limit":1})
      }

      assert %{
               "type" => "tool_search_call",
               "id" => id,
               "call_id" => "search-1",
               "status" => "completed",
               "execution" => "client",
               "arguments" => %{"query" => "calendar create", "limit" => 1}
             } = ToolSearch.public_search_call(plan, item)

      assert is_binary(id)
    end

    test "server mode search call carries a null call_id" do
      {:ok, _request, plan} = ToolSearch.plan(base_request([deferred_tool("bx_news", "新闻")]))

      item = %{
        "type" => "function_call",
        "name" => "tool_search",
        "call_id" => "call_abc",
        "arguments" => ~s({"paths":["bx_news"]})
      }

      public = ToolSearch.public_search_call(plan, item)
      assert public["call_id"] == nil
      assert public["execution"] == "server"
      assert public["arguments"] == %{"paths" => ["bx_news"]}
      refute Map.has_key?(public, "provider_call_id")
    end

    test "server mode output stays in the official null-call-id shape" do
      {:ok, _request, plan} = ToolSearch.plan(base_request([deferred_tool("bx_news", "新闻")]))

      call_item = %{"type" => "function_call", "call_id" => "call_abc"}
      assert {:ok, loaded} = ToolSearch.search_paths(plan, ["bx_news"])

      output = ToolSearch.public_search_output(plan, call_item, loaded)
      assert output["type"] == "tool_search_output"
      assert output["call_id"] == nil
      assert output["execution"] == "server"
      refute Map.has_key?(output, "provider_call_id")

      assert [
               %{
                 "type" => "namespace",
                 "name" => "functions",
                 "description" => "",
                 "tools" => [%{"name" => "bx_news", "defer_loading" => true}]
               }
             ] = output["tools"]
    end

    test "load_tools merges loaded tools once and reuses the unchanged plan" do
      {:ok, provider_request, plan} =
        ToolSearch.plan(base_request([deferred_tool("bx_news", "新闻")]))

      assert {:ok, loaded} = ToolSearch.search_paths(plan, ["bx_news"])

      assert {:ok, loaded_plan, tools} =
               ToolSearch.load_tools(plan, provider_request["tools"], loaded)

      assert Enum.count(tools, &(&1["name"] == "bx_news")) == 1
      refute Map.has_key?(Enum.find(tools, &(&1["name"] == "bx_news")), "defer_loading")

      assert {:ok, ^loaded_plan, ^tools} = ToolSearch.load_tools(loaded_plan, tools, loaded)
      assert Enum.count(tools, &(&1["name"] == "bx_news")) == 1
    end
  end

  describe "parse_search_arguments/1" do
    test "parses object and string arguments with limit bounds" do
      assert %{query: "行情", limit: 3} =
               ToolSearch.parse_search_arguments(%{
                 "arguments" => %{"query" => "行情", "limit" => 3}
               })

      assert %{query: "calendar create", limit: 8} =
               ToolSearch.parse_search_arguments(%{
                 "arguments" => ~s({"query":"calendar create"})
               })

      assert %{query: "", limit: 8} = ToolSearch.parse_search_arguments(%{})

      assert %{limit: 50} =
               ToolSearch.parse_search_arguments(%{
                 "arguments" => %{"query" => "q", "limit" => 999}
               })
    end
  end

  describe "hosted path selection" do
    test "loads exact root and namespace paths without silently truncating" do
      namespace = %{
        "type" => "namespace",
        "name" => "crm",
        "description" => "CRM tools",
        "tools" => [
          deferred_tool("get_customer", "Get a customer"),
          deferred_tool("list_orders", "List orders")
        ]
      }

      {:ok, _request, plan} =
        ToolSearch.plan(
          base_request([
            deferred_tool("get_weather", "Weather lookup"),
            namespace,
            %{"type" => "tool_search"}
          ])
        )

      assert {:ok, %{paths: ["crm", "get_weather"]}} =
               ToolSearch.parse_search_arguments(plan, %{
                 "arguments" => ~s({"paths":["crm","get_weather"]})
               })

      assert {:ok, loaded} = ToolSearch.search_paths(plan, ["crm", "get_weather"])

      assert Enum.map(loaded, &{&1["namespace"], &1["name"]}) == [
               {"crm", "get_customer"},
               {"crm", "list_orders"},
               {nil, "get_weather"}
             ]

      assert {:error, {:unknown_tool_search_path, "crm.list_orders"}} =
               ToolSearch.search_paths(plan, ["crm.list_orders"])
    end

    test "rejects malformed hosted arguments before search execution" do
      {:ok, _request, plan} =
        ToolSearch.plan(base_request([deferred_tool("bx_news", "News")]))

      assert {:error, {:invalid_tool_search_arguments, :invalid_shape}} =
               ToolSearch.parse_search_arguments(plan, %{
                 "arguments" => ~s({"query":"news"})
               })

      assert {:error, {:invalid_tool_search_arguments, :duplicate_path}} =
               ToolSearch.parse_search_arguments(plan, %{
                 "arguments" => %{"paths" => ["bx_news", "bx_news"]}
               })

      assert {:error, {:invalid_tool_search_arguments, :invalid_shape}} =
               ToolSearch.parse_search_arguments(plan, %{
                 "arguments" => %{"paths" => ["bx_news"], "limit" => 1}
               })

      assert {:error, {:unknown_tool_search_path, "missing"}} =
               ToolSearch.search_paths(plan, ["missing"])
    end

    test "rejects root and namespace surface path collisions during planning" do
      namespace = %{
        "type" => "namespace",
        "name" => "crm",
        "description" => "CRM tools",
        "tools" => [deferred_tool("lookup", "Lookup")]
      }

      assert {:error, {:invalid_tool_search, {:surface_path_collision, "crm"}}} =
               ToolSearch.plan(
                 base_request([
                   deferred_tool("crm", "Root CRM function"),
                   namespace,
                   %{"type" => "tool_search"}
                 ])
               )
    end

    test "rejects a namespace expansion beyond the atomic result budget" do
      namespace = %{
        "type" => "namespace",
        "name" => "large",
        "description" => "Large tool set",
        "tools" =>
          Enum.map(1..51, fn index ->
            deferred_tool("tool_#{index}", "Capability #{index}")
          end)
      }

      {:ok, _request, plan} =
        ToolSearch.plan(
          base_request([
            namespace,
            %{"type" => "tool_search"}
          ])
        )

      assert {:error, {:tool_search_result_limit_exceeded, 51, 50}} =
               ToolSearch.search_paths(plan, ["large"])
    end
  end

  describe "Index.tokenize/1" do
    test "splits latin identifiers and emits han bigrams" do
      assert Index.tokenize("bullx_market_data") == ["bullx", "market", "data"]
      assert Index.tokenize("A股龙虎榜") == ["a", "股龙", "龙虎", "虎榜"]
      assert Index.tokenize("单") == ["单"]
      assert Index.tokenize("  ") == []
    end
  end
end
