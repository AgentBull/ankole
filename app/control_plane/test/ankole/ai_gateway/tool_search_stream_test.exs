defmodule Ankole.AIGateway.ToolSearchStreamTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ToolSearch

  defp deferred_tool(name, description) do
    %{
      "type" => "function",
      "name" => name,
      "description" => description,
      "defer_loading" => true,
      "parameters" => %{"type" => "object", "properties" => %{}}
    }
  end

  defp new_state(request, public_request \\ %{}, meta \\ %{}) do
    {:ok, provider_request, plan} = ToolSearch.plan(request)

    state =
      State.new("subject-uid", public_request, meta,
        tool_loop: %{plan: plan, provider_request: provider_request}
      )

    {state, provider_request}
  end

  defp observe!(state, event, fallback \\ 0) do
    {:ok, state, events, status} = State.observe(state, event, fallback)
    {state, events, status}
  end

  defp search_call_events(call_id, arguments, seq_base \\ 0) do
    [
      %{
        "type" => "response.created",
        "sequence_number" => seq_base,
        "response" => %{"id" => "resp_p"}
      },
      %{
        "type" => "response.output_item.added",
        "sequence_number" => seq_base + 1,
        "output_index" => 0,
        "item" => %{"type" => "function_call", "name" => "tool_search", "id" => "fc_1"}
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "sequence_number" => seq_base + 2,
        "output_index" => 0,
        "item_id" => "fc_1",
        "delta" => arguments
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => seq_base + 3,
        "output_index" => 0,
        "item" => search_call_item(call_id, arguments)
      }
    ]
  end

  defp search_call_item(call_id, arguments) do
    %{
      "type" => "function_call",
      "id" => "fc_1",
      "name" => "tool_search",
      "call_id" => call_id,
      "status" => "completed",
      "arguments" => arguments
    }
  end

  defp completed_event(output, seq, usage \\ nil, tool_usage \\ nil) do
    response =
      %{"id" => "resp_p", "object" => "response", "status" => "completed", "output" => output}

    response = if usage, do: Map.put(response, "usage", usage), else: response
    response = if tool_usage, do: Map.put(response, "tool_usage", tool_usage), else: response
    %{"type" => "response.completed", "sequence_number" => seq, "response" => response}
  end

  describe "client mode" do
    test "rewrites the search call and finalizes with codex-shaped items" do
      {state, _provider_request} =
        new_state(%{
          "model" => "gpt-5.6",
          "tools" => [%{"type" => "tool_search", "execution" => "client"}],
          "input" => []
        })

      arguments = ~s({"query":"calendar create","limit":1})

      {state, events, statuses} =
        Enum.reduce(search_call_events("search-1", arguments), {state, [], []}, fn event,
                                                                                   {state, all,
                                                                                    statuses} ->
          {state, events, status} = observe!(state, event)
          {state, all ++ events, statuses ++ [status]}
        end)

      assert Enum.all?(statuses, &(&1 == :continue))

      types = Enum.map(events, & &1["type"])
      assert types == ["response.created", "response.output_item.done"]

      [_, done] = events
      assert done["item"]["type"] == "tool_search_call"
      assert done["item"]["call_id"] == "search-1"
      assert done["item"]["execution"] == "client"
      assert done["item"]["arguments"] == %{"query" => "calendar create", "limit" => 1}

      {_state, [terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([search_call_item("search-1", arguments)], 4))

      assert terminal["type"] == "response.completed"

      assert [%{"type" => "tool_search_call", "call_id" => "search-1"}] =
               terminal["response"]["output"]

      assert [%{"type" => "tool_search_call"}] = outcome.public_items

      sequences = Enum.map([hd(events), List.last(events), terminal], & &1["sequence_number"])
      assert sequences == [0, 1, 2]
    end

    test "max_tool_calls waits for the provider terminal before closing a client search" do
      request = %{
        "model" => "gpt-5.6",
        "max_tool_calls" => 1,
        "tools" => [%{"type" => "tool_search", "execution" => "client"}],
        "input" => []
      }

      {state, _provider_request} =
        new_state(request, request, %{"api_resolver" => :openai_responses})

      arguments = ~s({"query":"calendar create","limit":1})

      {state, events, statuses} =
        Enum.reduce(search_call_events("search-1", arguments), {state, [], []}, fn event,
                                                                                   {state, all,
                                                                                    statuses} ->
          {state, emitted, status} = observe!(state, event)
          {state, all ++ emitted, statuses ++ [status]}
        end)

      assert Enum.all?(statuses, &(&1 == :continue))
      assert Enum.map(events, & &1["type"]) == ["response.created", "response.output_item.done"]

      {_state, [terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([search_call_item("search-1", arguments)], 4))

      assert terminal["type"] == "response.completed"
      assert Enum.map(outcome.public_items, & &1["type"]) == ["tool_search_call"]
    end

    test "restores one namespaced function call across streamed and terminal output" do
      namespace = %{
        "type" => "namespace",
        "name" => "mcp__finance",
        "description" => "Financial data tools",
        "tools" => [
          %{
            "type" => "function",
            "name" => "get_quote",
            "description" => "Get one quote",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        ]
      }

      {state, _provider_request} =
        new_state(%{
          "model" => "gpt-5.6",
          "tools" => [namespace, %{"type" => "tool_search", "execution" => "client"}],
          "input" => []
        })

      provider_call = %{
        "type" => "function_call",
        "id" => "fc_quote",
        "name" => "mcp__finance__get_quote",
        "call_id" => "call_quote",
        "status" => "completed",
        "arguments" => ~s({"symbol":"600519.SH"})
      }

      {state, [done], :continue} =
        observe!(state, %{
          "type" => "response.output_item.done",
          "sequence_number" => 1,
          "item" => provider_call
        })

      assert done["item"]["namespace"] == "mcp__finance"
      assert done["item"]["name"] == "get_quote"

      {_state, [terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([provider_call], 2))

      assert [
               %{
                 "id" => "fc_quote",
                 "call_id" => "call_quote",
                 "namespace" => "mcp__finance",
                 "name" => "get_quote"
               }
             ] = terminal["response"]["output"]

      assert length(outcome.public_items) == 1
    end
  end

  describe "server mode" do
    setup do
      request = %{
        "model" => "gpt-5.6",
        "tools" => [
          %{"type" => "function", "name" => "get_weather", "description" => "Weather lookup"},
          deferred_tool("bx_market_data", "A股行情数据查询"),
          deferred_tool("bx_news", "新闻资讯")
        ],
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "查行情"}]
          }
        ]
      }

      {state, provider_request} = new_state(request)
      %{state: state, provider_request: provider_request, request: request}
    end

    test "runs a continuation round and finalizes with merged output", %{
      state: state,
      provider_request: provider_request
    } do
      arguments = ~s({"paths":["bx_market_data"]})

      {state, first_round_events, _statuses} =
        Enum.reduce(search_call_events("call_1", arguments), {state, [], []}, fn event,
                                                                                 {state, all,
                                                                                  statuses} ->
          {state, events, status} = observe!(state, event)
          {state, all ++ events, statuses ++ [status]}
        end)

      search_call_event =
        Enum.find(first_round_events, &(&1["type"] == "response.output_item.done"))

      usage_one = %{"input_tokens" => 100, "output_tokens" => 10}
      tool_usage_one = %{"image_gen" => %{"input_tokens" => 3, "output_tokens" => 1}}

      {state, round_events, {:round, continuation_request}} =
        observe!(
          state,
          completed_event(
            [search_call_item("call_1", arguments)],
            4,
            usage_one,
            tool_usage_one
          )
        )

      assert [output_event] = round_events
      assert output_event["type"] == "response.output_item.done"
      assert output_event["item"]["type"] == "tool_search_output"
      assert output_event["item"]["execution"] == "server"
      assert output_event["item"]["call_id"] == nil
      assert output_event["output_index"] == 1
      assert is_binary(search_call_event["item"]["id"])
      assert is_binary(output_event["item"]["id"])
      refute search_call_event["item"]["id"] == output_event["item"]["id"]

      assert [%{"name" => "bx_market_data", "defer_loading" => true}] =
               output_event["item"]["tools"]

      continuation_tools = Enum.map(continuation_request["tools"], & &1["name"])
      assert "get_weather" in continuation_tools
      assert "tool_search" in continuation_tools
      assert "bx_market_data" in continuation_tools
      refute "bx_news" in continuation_tools

      original_input_length = length(provider_request["input"])
      continuation_input = continuation_request["input"]
      assert length(continuation_input) == original_input_length + 2

      [call, output] = Enum.drop(continuation_input, original_input_length)
      assert call["type"] == "function_call"
      assert call["name"] == "tool_search"
      assert output["type"] == "function_call_output"
      assert output["call_id"] == "call_1"
      assert output["output"] =~ "bx_market_data"

      # Round two: suppressed lifecycle, then a final message and terminal.
      {state, events, :continue} =
        observe!(state, %{
          "type" => "response.created",
          "sequence_number" => 0,
          "response" => %{"id" => "resp_p2"}
        })

      assert events == []

      {state, events, :continue} =
        observe!(state, %{
          "type" => "response.queued",
          "sequence_number" => 0,
          "response" => %{"id" => "resp_p2", "status" => "queued"}
        })

      assert events == []

      {state, events, :continue} =
        observe!(state, %{
          "type" => "response.in_progress",
          "sequence_number" => 0,
          "response" => %{"id" => "resp_p2", "status" => "in_progress"}
        })

      assert events == []

      message_item = %{
        "id" => "fc_1",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "行情如下"}]
      }

      {state, [added_event], :continue} =
        observe!(state, %{
          "type" => "response.output_item.added",
          "sequence_number" => 1,
          "output_index" => 0,
          "item" => Map.put(message_item, "status", "in_progress")
        })

      {state, [delta_event], :continue} =
        observe!(state, %{
          "type" => "response.output_text.delta",
          "sequence_number" => 2,
          "output_index" => 0,
          "content_index" => 0,
          "item_id" => "fc_1",
          "delta" => "行情如下"
        })

      {state, [message_event], :continue} =
        observe!(state, %{
          "type" => "response.output_item.done",
          "sequence_number" => 3,
          "output_index" => 0,
          "item" => message_item
        })

      assert Enum.map([added_event, delta_event, message_event], & &1["output_index"]) == [
               2,
               2,
               2
             ]

      assert delta_event["content_index"] == 0
      assert added_event["item"]["id"] == message_event["item"]["id"]
      assert delta_event["item_id"] == message_event["item"]["id"]
      refute message_event["item"]["id"] == "fc_1"

      usage_two = %{"input_tokens" => 40, "output_tokens" => 20}
      tool_usage_two = %{"image_gen" => %{"input_tokens" => 2, "output_tokens" => 1}}

      {_state, [terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([message_item], 4, usage_two, tool_usage_two))

      output_types = Enum.map(terminal["response"]["output"], & &1["type"])
      assert output_types == ["tool_search_call", "tool_search_output", "message"]

      output_ids = Enum.map(terminal["response"]["output"], & &1["id"])
      assert Enum.uniq(output_ids) == output_ids

      assert output_ids == [
               search_call_event["item"]["id"],
               output_event["item"]["id"],
               message_event["item"]["id"]
             ]

      assert terminal["response"]["usage"] == %{"input_tokens" => 140, "output_tokens" => 30}

      assert terminal["response"]["tool_usage"] == %{
               "image_gen" => %{"input_tokens" => 5, "output_tokens" => 2}
             }

      assert Enum.map(outcome.public_items, & &1["type"]) ==
               ["tool_search_call", "tool_search_output", "message"]

      sequences =
        [message_event["sequence_number"], terminal["sequence_number"]]

      assert sequences == [Enum.at(sequences, 0), Enum.at(sequences, 0) + 1]
    end

    test "admits a terminal-only search call before its output and the next round", %{
      state: state
    } do
      arguments = ~s({"paths":["bx_market_data"]})
      search_call = search_call_item("call_terminal", arguments)

      {state, [search_event, search_output_event], {:round, _continuation_request}} =
        observe!(state, completed_event([search_call], 0))

      assert search_event["item"]["type"] == "tool_search_call"
      assert search_output_event["item"]["type"] == "tool_search_output"

      message = %{
        "id" => "msg_terminal",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "done"}]
      }

      {_state, [message_event, terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([message], 0))

      item_events = [search_event, search_output_event, message_event]

      assert Enum.map(item_events, &get_in(&1, ["item", "type"])) == [
               "tool_search_call",
               "tool_search_output",
               "message"
             ]

      assert Enum.map(item_events, & &1["output_index"]) == [0, 1, 2]

      ids = Enum.map(item_events, &get_in(&1, ["item", "id"]))
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(ids) == ids

      assert Enum.map(terminal["response"]["output"], & &1["id"]) == ids

      assert Enum.map(outcome.public_items, & &1["type"]) == [
               "tool_search_call",
               "tool_search_output",
               "message"
             ]
    end

    test "isolates reused pair ids across provider rounds" do
      request = %{
        "model" => "gpt-5.6",
        "tools" => [
          %{
            "type" => "function",
            "name" => "get_weather",
            "description" => "Weather lookup",
            "parameters" => %{"type" => "object", "properties" => %{}}
          },
          %{
            "type" => "function",
            "name" => "market",
            "description" => "Market data",
            "allowed_callers" => ["programmatic"],
            "parameters" => %{"type" => "object", "properties" => %{}}
          },
          %{"type" => "programmatic_tool_calling"}
        ],
        "input" => []
      }

      {state, _provider_request} = new_state(request)

      program_call = %{
        "type" => "function_call",
        "id" => "fc_program_terminal",
        "name" => "program",
        "call_id" => "program_terminal",
        "status" => "completed",
        "arguments" => Ankole.JSON.encode!(%{"code" => "text(42)"})
      }

      {state, [program_event], {:local, [_job], context}} =
        observe!(state, completed_event([program_call], 0))

      assert program_event["item"]["type"] == "program"
      assert program_event["output_index"] == 0
      program_pair_id = program_event["item"]["call_id"]
      assert is_binary(program_pair_id)

      outcomes = [
        %{
          call_id: "program_terminal",
          outcome: %{
            status: :completed,
            output: [%{kind: "text", value: "42"}],
            pending_calls: [],
            error: nil,
            error_code: nil
          }
        }
      ]

      {:ok, state, [program_output_event], {:round, _continuation_request}} =
        State.complete_local_effect(state, context, outcomes)

      assert program_output_event["item"]["type"] == "program_output"
      assert program_output_event["output_index"] == 1
      assert program_output_event["item"]["call_id"] == program_pair_id

      direct_call = %{
        "id" => "fc_after_program",
        "type" => "function_call",
        "name" => "get_weather",
        "call_id" => "program_terminal",
        "status" => "completed",
        "arguments" => ~s({"city":"Singapore"})
      }

      {_state, [direct_event, terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([direct_call], 0))

      direct_pair_id = direct_event["item"]["call_id"]
      assert is_binary(direct_pair_id)
      refute direct_pair_id == program_pair_id

      item_events = [program_event, program_output_event, direct_event]

      assert Enum.map(item_events, &get_in(&1, ["item", "type"])) == [
               "program",
               "program_output",
               "function_call"
             ]

      assert Enum.map(item_events, & &1["output_index"]) == [0, 1, 2]

      ids = Enum.map(item_events, &get_in(&1, ["item", "id"]))
      assert Enum.all?(ids, &(is_binary(&1) and &1 != ""))
      assert Enum.uniq(ids) == ids
      assert Enum.map(terminal["response"]["output"], & &1["id"]) == ids

      assert Enum.map(outcome.public_items, & &1["type"]) == [
               "program",
               "program_output",
               "function_call"
             ]

      [terminal_program, terminal_program_output, terminal_direct] =
        terminal["response"]["output"]

      assert terminal_program["call_id"] == program_pair_id
      assert terminal_program_output["call_id"] == program_pair_id
      assert terminal_direct["call_id"] == direct_pair_id
    end

    test "keeps a local nested caller on its program pair id" do
      request = %{
        "model" => "gpt-5.6",
        "tools" => [
          %{
            "type" => "function",
            "name" => "market",
            "description" => "Market data",
            "allowed_callers" => ["programmatic"],
            "parameters" => %{"type" => "object", "properties" => %{}}
          },
          %{"type" => "programmatic_tool_calling"}
        ],
        "input" => []
      }

      {state, _provider_request} = new_state(request)

      program_call = %{
        "type" => "function_call",
        "id" => "fc_program_nested",
        "name" => "program",
        "call_id" => "program_nested",
        "status" => "completed",
        "arguments" => Ankole.JSON.encode!(%{"code" => "text(market())"})
      }

      {state, [program_event], {:local, [_job], context}} =
        observe!(state, completed_event([program_call], 0))

      outcomes = [
        %{
          call_id: "program_nested",
          outcome: %{
            status: :pending,
            output: [],
            pending_calls: [%{name: "market", arguments: %{}}],
            error: nil,
            error_code: nil
          }
        }
      ]

      {:ok, _state, [nested_event, terminal], {:terminal, outcome, :keep_upstream}} =
        State.complete_local_effect(state, context, outcomes)

      program_pair_id = program_event["item"]["call_id"]
      assert nested_event["item"]["type"] == "function_call"
      assert get_in(nested_event, ["item", "caller", "caller_id"]) == program_pair_id

      assert [terminal_program, terminal_nested] = terminal["response"]["output"]
      assert terminal_program["call_id"] == program_pair_id
      assert get_in(terminal_nested, ["caller", "caller_id"]) == program_pair_id
      assert Enum.map(outcome.public_items, & &1["type"]) == ["program", "function_call"]
    end

    test "keeps an MCP approval pair together after a cross-round item id collision" do
      request = %{
        "model" => "gpt-5.6",
        "tools" => [
          %{
            "type" => "function",
            "name" => "market",
            "description" => "Market data",
            "allowed_callers" => ["programmatic"],
            "parameters" => %{"type" => "object", "properties" => %{}}
          },
          %{"type" => "programmatic_tool_calling"},
          %{
            "type" => "mcp",
            "server_label" => "inventory",
            "server_url" => "https://mcp.example.test"
          }
        ],
        "input" => []
      }

      {state, _provider_request} = new_state(request)

      program_call = %{
        "type" => "function_call",
        "id" => "approval_collision",
        "name" => "program",
        "call_id" => "program_before_approval",
        "status" => "completed",
        "arguments" => Ankole.JSON.encode!(%{"code" => "text(42)"})
      }

      {state, [program_event], {:local, [_job], context}} =
        observe!(state, completed_event([program_call], 0))

      assert program_event["item"]["id"] == "approval_collision"

      outcomes = [
        %{
          call_id: "program_before_approval",
          outcome: %{
            status: :completed,
            output: [%{kind: "text", value: "42"}],
            pending_calls: [],
            error: nil,
            error_code: nil
          }
        }
      ]

      {:ok, state, [_program_output_event], {:round, _continuation_request}} =
        State.complete_local_effect(state, context, outcomes)

      approval_request = %{
        "id" => "approval_collision",
        "type" => "mcp_approval_request",
        "arguments" => ~s({"sku":"A-1"}),
        "name" => "update",
        "server_label" => "inventory"
      }

      approval_response = %{
        "id" => "approval_response",
        "type" => "mcp_approval_response",
        "approval_request_id" => "approval_collision",
        "approve" => true
      }

      {_state, [request_event, response_event, terminal], {:terminal, _outcome, :keep_upstream}} =
        observe!(state, completed_event([approval_request, approval_response], 0))

      public_approval_id = request_event["item"]["id"]
      refute public_approval_id == "approval_collision"
      assert response_event["item"]["approval_request_id"] == public_approval_id

      terminal_request =
        Enum.find(terminal["response"]["output"], &(&1["type"] == "mcp_approval_request"))

      terminal_response =
        Enum.find(terminal["response"]["output"], &(&1["type"] == "mcp_approval_response"))

      assert terminal_request["id"] == public_approval_id
      assert terminal_response["approval_request_id"] == public_approval_id
    end

    test "max_tool_calls settles the exact server search and disables further attempts", %{
      request: request
    } do
      request = Map.put(request, "max_tool_calls", 1)

      {state, _provider_request} =
        new_state(request, request, %{"api_resolver" => :openai_responses})

      arguments = ~s({"paths":["bx_market_data"]})

      {state, _events, statuses} =
        Enum.reduce(search_call_events("call_1", arguments), {state, [], []}, fn event,
                                                                                 {state, all,
                                                                                  statuses} ->
          {state, events, status} = observe!(state, event)
          {state, all ++ events, statuses ++ [status]}
        end)

      assert Enum.all?(statuses, &(&1 == :continue))

      {state, [output_event], {:round, continuation_request}} =
        observe!(state, completed_event([search_call_item("call_1", arguments)], 4))

      assert output_event["item"]["type"] == "tool_search_output"
      refute Map.has_key?(continuation_request, "max_tool_calls")

      refute Enum.any?(
               ToolSearch.list_tools(continuation_request),
               &(&1["name"] == "tool_search")
             )

      message = %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "done"}]
      }

      {state, _events, :continue} =
        observe!(state, %{
          "type" => "response.output_item.done",
          "sequence_number" => 0,
          "item" => message
        })

      {_state, [terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([message], 1))

      assert terminal["type"] == "response.completed"

      assert Enum.map(outcome.public_items, & &1["type"]) == [
               "tool_search_call",
               "tool_search_output",
               "message"
             ]
    end

    test "max_tool_calls admits only the first server search in one provider batch", %{
      request: request
    } do
      request = Map.put(request, "max_tool_calls", 1)

      {state, _provider_request} =
        new_state(request, request, %{"api_resolver" => :openai_responses})

      first_arguments = ~s({"paths":["bx_market_data"]})
      second_arguments = ~s({"paths":["bx_news"]})
      first = search_call_item("call_1", first_arguments)
      second = search_call_item("call_2", second_arguments) |> Map.put("id", "fc_2")

      second_events = [
        %{
          "type" => "response.output_item.added",
          "sequence_number" => 4,
          "item" => %{"type" => "function_call", "name" => "tool_search", "id" => "fc_2"}
        },
        %{
          "type" => "response.function_call_arguments.delta",
          "sequence_number" => 5,
          "item_id" => "fc_2",
          "delta" => second_arguments
        },
        %{"type" => "response.output_item.done", "sequence_number" => 6, "item" => second}
      ]

      {state, streamed_events, _statuses} =
        Enum.reduce(
          search_call_events("call_1", first_arguments) ++ second_events,
          {state, [], []},
          fn event, {state, events, statuses} ->
            {state, emitted, status} = observe!(state, event)
            {state, events ++ emitted, statuses ++ [status]}
          end
        )

      assert Enum.map(streamed_events, & &1["type"]) == [
               "response.created",
               "response.output_item.done"
             ]

      {_, [output_event], {:round, continuation_request}} =
        observe!(state, completed_event([first, second], 7))

      assert output_event["item"]["type"] == "tool_search_output"
      assert output_event["sequence_number"] == 2
      assert [%{"name" => "bx_market_data"}] = output_event["item"]["tools"]

      encoded_input = Ankole.JSON.encode!(continuation_request["input"])
      assert encoded_input =~ "call_1"
      refute encoded_input =~ "call_2"
      refute encoded_input =~ "bx_news"
    end

    test "exhausted round budget finalizes as an explicit incomplete", %{state: state} do
      arguments = ~s({"paths":["bx_market_data"]})

      run_round = fn state, round ->
        {state, _events, _statuses} =
          Enum.reduce(search_call_events("call_#{round}", arguments), {state, [], []}, fn event,
                                                                                          {state,
                                                                                           all,
                                                                                           statuses} ->
            {state, events, status} = observe!(state, event)
            {state, all ++ events, statuses ++ [status]}
          end)

        {state, _events, status} =
          observe!(state, completed_event([search_call_item("call_#{round}", arguments)], 4))

        {state, status}
      end

      {state, statuses} =
        Enum.reduce(1..16, {state, []}, fn round, {state, statuses} ->
          {state, status} = run_round.(state, round)
          {state, statuses ++ [status]}
        end)

      assert Enum.all?(statuses, &match?({:round, _request}, &1))

      {_state, status} = run_round.(state, 17)

      assert {:terminal, outcome, :keep_upstream} = status
      assert outcome.terminal_response["status"] == "incomplete"

      assert outcome.terminal_response["incomplete_details"] == %{
               "reason" => "tool_loop_rounds_exhausted"
             }
    end

    test "finalizes alongside pending client calls with collision-safe local item ids", %{
      state: state,
      request: request
    } do
      arguments = ~s({"paths":["bx_market_data"]})

      {:ok, _provider_request, plan} = ToolSearch.plan(request)

      search_output_id =
        plan
        |> ToolSearch.public_search_output(search_call_item("call_1", arguments), [])
        |> Map.fetch!("id")

      {state, _events, _statuses} =
        Enum.reduce(search_call_events("call_1", arguments), {state, [], []}, fn event,
                                                                                 {state, all,
                                                                                  statuses} ->
          {state, events, status} = observe!(state, event)
          {state, all ++ events, statuses ++ [status]}
        end)

      weather_call = %{
        "type" => "function_call",
        "id" => search_output_id,
        "name" => "get_weather",
        "call_id" => "call_w",
        "status" => "completed",
        "arguments" => ~s({"city":"SH"})
      }

      {state, [weather_event], :continue} =
        observe!(state, %{
          "type" => "response.output_item.done",
          "sequence_number" => 4,
          "item" => weather_call
        })

      assert weather_event["item"]["type"] == "function_call"

      terminal_output = [search_call_item("call_1", arguments), weather_call]

      {_state, events, {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event(terminal_output, 5))

      assert [output_event, terminal] = events
      assert output_event["item"]["type"] == "tool_search_output"
      refute output_event["item"]["id"] == weather_event["item"]["id"]

      output_types = Enum.map(terminal["response"]["output"], & &1["type"])
      assert output_types == ["tool_search_call", "function_call", "tool_search_output"]

      terminal_ids = Enum.map(terminal["response"]["output"], & &1["id"])
      assert Enum.uniq(terminal_ids) == terminal_ids
      assert List.last(terminal_ids) == output_event["item"]["id"]

      assert Enum.map(outcome.public_items, & &1["type"]) ==
               ["tool_search_call", "function_call", "tool_search_output"]
    end
  end
end
