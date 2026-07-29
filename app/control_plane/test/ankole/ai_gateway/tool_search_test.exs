defmodule Ankole.AIGateway.ToolSearchTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ToolSearch
  alias Ankole.AIGateway.ToolSearch.Index

  # Golden wire sample from codex rust-v0.146.0
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
      assert search_tool["parameters"]["required"] == ["query"]
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
      assert Enum.map(carrier["tools"], & &1["name"]) == ["get_weather", "tool_search"]
      assert Enum.at(remaining_input, 0)["role"] == "developer"

      [loaded] = ToolSearch.search(plan, "行情", 5)
      {_plan, next_tools} = ToolSearch.load_tools(plan, carrier["tools"], [loaded])
      continuation = ToolSearch.put_tools(provider_request, next_tools)

      assert continuation["tools"] == nil

      assert Enum.map(hd(continuation["input"])["tools"], & &1["name"]) == [
               "get_weather",
               "tool_search",
               "bx_market_data"
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

      assert {:error, {:invalid_tool_search, {:invalid_namespace, "agents"}}} =
               ToolSearch.plan(request)
    end

    test "flattens namespace children only at the provider boundary" do
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
               ToolSearch.plan(base_request([namespace, %{"type" => "tool_search"}]))

      assert Enum.map(plan.catalog, & &1["__ankole_public_name"]) == [
               "stock_price",
               "company_news"
             ]

      assert Enum.map(provider_request["tools"], & &1["name"]) == ["tool_search"]
      assert hd(provider_request["tools"])["description"] =~ "mcp__finance"
      refute hd(provider_request["tools"])["description"] =~ "stock_price"

      [loaded] = ToolSearch.search(plan, "股票行情", 5)
      assert loaded["__ankole_public_name"] == "stock_price"

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

      {plan, provider_tools} = ToolSearch.load_tools(plan, provider_request["tools"], [loaded])
      [loaded_provider, _search] = Enum.sort_by(provider_tools, & &1["name"])
      refute Map.has_key?(loaded_provider, "namespace")
      refute Map.has_key?(loaded_provider, "defer_loading")

      public_call =
        ToolSearch.public_function_call(plan, %{
          "type" => "function_call",
          "name" => loaded_provider["name"],
          "call_id" => "call_price",
          "arguments" => "{}"
        })

      assert public_call["namespace"] == "mcp__finance"
      assert public_call["name"] == "stock_price"
    end

    test "rejects a base tool colliding with the search tool name" do
      request =
        base_request([
          %{"type" => "function", "name" => "tool_search"},
          deferred_tool("bx_market_data", "行情")
        ])

      assert {:error, {:invalid_tool_search, {:tool_name_collision, "tool_search"}}} =
               ToolSearch.plan(request)
    end

    test "rewrites replayed tool_search_call items into provider function calls" do
      request =
        base_request(
          [%{"type" => "tool_search", "execution" => "client"}],
          [@codex_tool_search_call]
        )

      assert {:ok, provider_request, _plan} = ToolSearch.plan(request)

      [call] = provider_request["input"]
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
          [@codex_tool_search_call, output_item]
        )

      assert {:ok, provider_request, plan} = ToolSearch.plan(request)

      [_call, output] = provider_request["input"]
      assert output["type"] == "function_call_output"
      assert output["call_id"] == "search-1"
      assert output["output"] =~ "bx_market_data"

      tool_names = Enum.map(provider_request["tools"], & &1["name"])
      assert "bx_market_data" in tool_names
      assert MapSet.member?(plan.loaded_names, "bx_market_data")

      [loaded_tool] = Enum.filter(provider_request["tools"], &(&1["name"] == "bx_market_data"))
      refute Map.has_key?(loaded_tool, "defer_loading")
    end

    test "replays Codex 0.146 namespace search output and restores namespaced calls" do
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
      refute Map.has_key?(provider_call, "namespace")
      assert provider_call["name"] == "mcp__calendar__create_event"

      public_call = ToolSearch.public_function_call(plan, provider_call)
      assert public_call["namespace"] == "mcp__calendar"
      assert public_call["name"] == "create_event"
    end

    test "keeps loaded tools out of the searchable listing" do
      loaded = deferred_tool("bx_market_data", "A股行情数据查询")

      output_item = %{
        "type" => "tool_search_output",
        "call_id" => "search-1",
        "execution" => "server",
        "tools" => [loaded]
      }

      request =
        base_request(
          [deferred_tool("bx_market_data", "A股行情数据查询"), deferred_tool("bx_news", "新闻")],
          [output_item]
        )

      assert {:ok, provider_request, _plan} = ToolSearch.plan(request)

      [search_tool] = Enum.filter(provider_request["tools"], &(&1["name"] == "tool_search"))
      refute search_tool["description"] =~ "bx_market_data:"
      assert search_tool["description"] =~ "bx_news"
    end
  end

  describe "search/3" do
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

    test "matches Chinese queries through bigram tokens", %{plan: plan} do
      assert [%{"name" => "bx_dragon_tiger"} = tool] = ToolSearch.search(plan, "龙虎榜", 5)
      assert tool["defer_loading"] == true
    end

    test "matches English queries through word tokens", %{plan: plan} do
      assert [%{"name" => "get_weather"}] = ToolSearch.search(plan, "weather forecast", 5)
    end

    test "matches tool name fragments split on underscores", %{plan: plan} do
      assert [%{"name" => "bx_market_data"} | _rest] = ToolSearch.search(plan, "market data", 5)
    end

    test "returns nothing for an unmatched or empty query", %{plan: plan} do
      assert ToolSearch.search(plan, "", 5) == []
      assert ToolSearch.search(plan, "unrelated topic zzz", 5) == []
    end

    test "returns eight tools by default" do
      catalog =
        Enum.map(1..12, fn index ->
          deferred_tool("market_metric_#{index}", "Shared market lookup #{index}")
        end)

      {:ok, _request, plan} = ToolSearch.plan(base_request(catalog))

      assert plan
             |> ToolSearch.search("market lookup", nil)
             |> length() == 8
    end

    test "indexes the owner-supplied MCP corpus and strips it from public and provider tools" do
      tool =
        deferred_tool("opaque_tool", "Generic lookup")
        |> Map.put(
          "__ankole_search_text",
          "raw-name canonical_name Market Title server.one initialize instructions security_id"
        )

      {:ok, provider_request, plan} = ToolSearch.plan(base_request([tool]))
      assert [loaded] = ToolSearch.search(plan, "security_id", nil)

      output =
        ToolSearch.public_search_output(
          plan,
          %{"id" => "fc_search", "call_id" => "call_search"},
          [loaded]
        )

      [public_tool] = output["tools"]
      refute Map.has_key?(public_tool, "__ankole_search_text")

      {_plan, provider_tools} = ToolSearch.load_tools(plan, provider_request["tools"], [loaded])
      provider_tool = Enum.find(provider_tools, &(&1["name"] == "opaque_tool"))
      refute Map.has_key?(provider_tool, "__ankole_search_text")
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
        "arguments" => ~s({"query":"新闻"})
      }

      public = ToolSearch.public_search_call(plan, item)
      assert public["call_id"] == nil
      assert public["execution"] == "server"
    end

    test "server mode output pairs loaded tools with the provider call" do
      {:ok, _request, plan} = ToolSearch.plan(base_request([deferred_tool("bx_news", "新闻")]))

      call_item = %{"type" => "function_call", "call_id" => "call_abc"}
      loaded = ToolSearch.search(plan, "新闻", 5)

      output = ToolSearch.public_search_output(plan, call_item, loaded)
      assert output["type"] == "tool_search_output"
      assert output["call_id"] == nil
      assert output["execution"] == "server"
      assert output["provider_call_id"] == "call_abc"
      assert [%{"name" => "bx_news", "defer_loading" => true}] = output["tools"]
    end

    test "load_tools merges loaded tools once and advances the round" do
      {:ok, provider_request, plan} =
        ToolSearch.plan(base_request([deferred_tool("bx_news", "新闻")]))

      loaded = ToolSearch.search(plan, "新闻", 5)

      {plan, tools} = ToolSearch.load_tools(plan, provider_request["tools"], loaded)
      assert Enum.count(tools, &(&1["name"] == "bx_news")) == 1
      refute Map.has_key?(Enum.find(tools, &(&1["name"] == "bx_news")), "defer_loading")
      assert plan.server_round == 1

      {plan, tools} = ToolSearch.load_tools(plan, tools, loaded)
      assert Enum.count(tools, &(&1["name"] == "bx_news")) == 1
      assert plan.server_round == 2
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

  describe "Index.tokenize/1" do
    test "splits latin identifiers and emits han bigrams" do
      assert Index.tokenize("bullx_market_data") == ["bullx", "market", "data"]
      assert Index.tokenize("A股龙虎榜") == ["a", "股龙", "龙虎", "虎榜"]
      assert Index.tokenize("单") == ["单"]
      assert Index.tokenize("  ") == []
    end
  end
end
