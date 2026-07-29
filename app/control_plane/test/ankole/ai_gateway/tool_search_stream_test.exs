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

  defp new_state(request) do
    {:ok, provider_request, plan} = ToolSearch.plan(request)

    state =
      State.new("subject-uid", %{}, %{},
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
        "item" => %{"type" => "function_call", "name" => "tool_search", "id" => "fc_1"}
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "sequence_number" => seq_base + 2,
        "item_id" => "fc_1",
        "delta" => arguments
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => seq_base + 3,
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
      %{state: state, provider_request: provider_request}
    end

    test "runs a continuation round and finalizes with merged output", %{
      state: state,
      provider_request: provider_request
    } do
      arguments = ~s({"query":"行情","limit":5})

      {state, _events, _statuses} =
        Enum.reduce(search_call_events("call_1", arguments), {state, [], []}, fn event,
                                                                                 {state, all,
                                                                                  statuses} ->
          {state, events, status} = observe!(state, event)
          {state, all ++ events, statuses ++ [status]}
        end)

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

      message_item = %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => "行情如下"}]
      }

      {state, [message_event], :continue} =
        observe!(state, %{
          "type" => "response.output_item.done",
          "sequence_number" => 1,
          "item" => message_item
        })

      usage_two = %{"input_tokens" => 40, "output_tokens" => 20}
      tool_usage_two = %{"image_gen" => %{"input_tokens" => 2, "output_tokens" => 1}}

      {_state, [terminal], {:terminal, outcome, :keep_upstream}} =
        observe!(state, completed_event([message_item], 2, usage_two, tool_usage_two))

      output_types = Enum.map(terminal["response"]["output"], & &1["type"])
      assert output_types == ["tool_search_call", "tool_search_output", "message"]

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

    test "exhausted round budget finalizes as an explicit incomplete", %{state: state} do
      arguments = ~s({"query":"行情"})

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
               "reason" => "tool_search_rounds_exhausted"
             }
    end

    test "finalizes alongside pending client calls after executing the search", %{state: state} do
      arguments = ~s({"query":"行情"})

      {state, _events, _statuses} =
        Enum.reduce(search_call_events("call_1", arguments), {state, [], []}, fn event,
                                                                                 {state, all,
                                                                                  statuses} ->
          {state, events, status} = observe!(state, event)
          {state, all ++ events, statuses ++ [status]}
        end)

      weather_call = %{
        "type" => "function_call",
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

      output_types = Enum.map(terminal["response"]["output"], & &1["type"])
      assert output_types == ["tool_search_call", "function_call", "tool_search_output"]

      assert Enum.map(outcome.public_items, & &1["type"]) ==
               ["tool_search_call", "function_call", "tool_search_output"]
    end
  end
end
