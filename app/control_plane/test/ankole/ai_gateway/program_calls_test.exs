defmodule Ankole.AIGateway.ProgramCallsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ResponseStream.State
  alias Ankole.AIGateway.ToolSearch
  alias Ankole.AIGateway.ToolSearch.StreamLoop

  defp market_tool(callers) do
    %{
      "type" => "function",
      "name" => "market",
      "description" => "行情查询",
      "allowed_callers" => callers,
      "parameters" => %{"type" => "object", "properties" => %{}}
    }
  end

  defp plan!(request) do
    {:ok, provider_request, plan} = ToolSearch.plan(request)
    {provider_request, plan}
  end

  defp ptc_tools(tools), do: tools ++ [%{"type" => "programmatic_tool_calling"}]

  describe "plan/1 PTC surface" do
    test "programmatic tools synthesize the program tool and strip allowed_callers" do
      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" =>
            ptc_tools([
              market_tool(["direct", "programmatic"]),
              %{"type" => "function", "name" => "weather"}
            ]),
          "input" => []
        })

      names = Enum.map(provider_request["tools"], & &1["name"])
      assert names == ["market", "weather", "program"]
      refute Enum.any?(provider_request["tools"], &Map.has_key?(&1, "allowed_callers"))

      assert plan.program.bindings == ["market"]
      assert plan.program.tool_name == "program"

      [program_tool] = Enum.filter(provider_request["tools"], &(&1["name"] == "program"))
      assert program_tool["description"] =~ "tools.<name>(args)"
      assert program_tool["description"] =~ "market"
      assert program_tool["parameters"]["required"] == ["code"]
    end

    test "synthesizes the program tool inside the responses-lite carrier" do
      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" => nil,
          "input" => [
            %{
              "type" => "additional_tools",
              "role" => "developer",
              "tools" => ptc_tools([market_tool(["direct", "programmatic"])])
            },
            %{"type" => "message", "role" => "developer", "content" => "Base instructions"}
          ]
        })

      assert provider_request["tools"] == nil
      assert plan.program.bindings == ["market"]

      assert Enum.map(hd(provider_request["input"])["tools"], & &1["name"]) == [
               "market",
               "program"
             ]
    end

    test "programmatic-only tools leave the model-visible array" do
      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" => ptc_tools([market_tool(["programmatic"])]),
          "input" => []
        })

      names = Enum.map(provider_request["tools"], & &1["name"])
      assert names == ["program"]
      assert plan.program.bindings == ["market"]
    end

    test "deferred namespace tools join PTC only after Tool Search loads them" do
      namespace = %{
        "type" => "namespace",
        "name" => "mcp__finance",
        "description" => "Financial data tools.",
        "tools" => [
          market_tool(["direct", "programmatic"])
          |> Map.put("defer_loading", true)
        ]
      }

      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" => ptc_tools([namespace, %{"type" => "tool_search"}]),
          "input" => []
        })

      assert plan.program == nil
      assert Enum.map(provider_request["tools"], & &1["name"]) == ["tool_search"]

      [loaded] = ToolSearch.search(plan, "行情", 5)
      {plan, provider_tools} = ToolSearch.load_tools(plan, provider_request["tools"], [loaded])

      assert plan.program.bindings == ["mcp__finance__market"]

      assert Enum.sort(Enum.map(provider_tools, & &1["name"])) == [
               "mcp__finance__market",
               "program",
               "tool_search"
             ]

      public =
        ToolSearch.public_function_call(
          plan,
          ToolSearch.nested_program_call("prog_1", 0, %{
            name: "mcp__finance__market",
            arguments: %{}
          })
        )

      assert public["namespace"] == "mcp__finance"
      assert public["name"] == "market"
    end

    test "allowed_callers without a PTC declaration do not synthesize a program" do
      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" => [market_tool(["direct", "programmatic"])],
          "input" => []
        })

      assert plan.program == nil
      assert Enum.map(provider_request["tools"], & &1["name"]) == ["market"]
      refute Map.has_key?(hd(provider_request["tools"]), "allowed_callers")
    end

    test "program history items rewrite into provider function call pairs" do
      program_item = %{
        "type" => "program",
        "call_id" => "prog_1",
        "code" => "text(1)",
        "fingerprint" => "abc"
      }

      output_item = %{
        "type" => "program_output",
        "call_id" => "prog_1",
        "status" => "completed",
        "result" => "1"
      }

      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" => ptc_tools([market_tool(["programmatic"])]),
          "input" => [program_item, output_item]
        })

      assert plan.pre_round == nil

      [call, output] = provider_request["input"]
      assert call["type"] == "function_call"
      assert call["name"] == "program"
      assert call["call_id"] == "prog_1"
      assert output["type"] == "function_call_output"
      assert output["call_id"] == "prog_1"
      assert output["output"] =~ "completed"
    end

    test "an unsettled program with answered nested calls becomes the pre-round" do
      code = ~s|const d = await tools.market({}); text(d);|
      fingerprint = ToolSearch.program_fingerprint(code, ["market"])

      input = [
        %{
          "type" => "program",
          "call_id" => "prog_1",
          "code" => code,
          "fingerprint" => fingerprint
        },
        %{
          "type" => "function_call",
          "call_id" => "prog_1_c0",
          "name" => "market",
          "arguments" => ~s({}),
          "caller" => %{"type" => "program", "caller_id" => "prog_1"}
        },
        %{
          "type" => "function_call_output",
          "call_id" => "prog_1_c0",
          "output" => ~s({"price":1700})
        }
      ]

      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" => ptc_tools([market_tool(["programmatic"])]),
          "input" => input
        })

      assert plan.pre_round.call_id == "prog_1"
      assert plan.pre_round.code == code

      assert plan.pre_round.memo == [
               %{"name" => "market", "arguments" => %{}, "output" => %{"price" => 1700}}
             ]

      # Nested caller items never reach the provider.
      [call] = provider_request["input"]
      assert call["name"] == "program"
    end

    test "unanswered nested calls fail loudly" do
      input = [
        %{"type" => "program", "call_id" => "prog_1", "code" => "x", "fingerprint" => "f"},
        %{
          "type" => "function_call",
          "call_id" => "prog_1_c0",
          "name" => "market",
          "arguments" => ~s({}),
          "caller" => %{"type" => "program", "caller_id" => "prog_1"}
        }
      ]

      assert {:error, {:invalid_program, {:program_calls_unanswered, "prog_1"}}} =
               ToolSearch.plan(%{
                 "model" => "gpt-5.6",
                 "tools" => ptc_tools([market_tool(["programmatic"])]),
                 "input" => input
               })
    end
  end

  describe "stream loop program rounds" do
    defp program_state(request, program_run) do
      {:ok, provider_request, plan} = ToolSearch.plan(request)

      State.new("subject-uid", %{}, %{},
        tool_loop: %{plan: plan, provider_request: provider_request, program_run: program_run}
      )
    end

    defp observe!(state, event) do
      {:ok, state, events, status} = State.observe(state, event, 0)
      {state, events, status}
    end

    defp program_call_item(code) do
      %{
        "type" => "function_call",
        "id" => "fc_p",
        "name" => "program",
        "call_id" => "prog_1",
        "status" => "completed",
        "arguments" => Ankole.JSON.encode!(%{"code" => code})
      }
    end

    defp completed_event(output) do
      %{
        "type" => "response.completed",
        "sequence_number" => 5,
        "response" => %{"id" => "resp_p", "status" => "completed", "output" => output}
      }
    end

    test "a completed program answers the model in a continuation round" do
      runner = fn code, bindings, memo ->
        assert code == "text(42)"
        assert bindings == ["market"]
        assert memo == []

        {:ok,
         %{
           status: :completed,
           output: [%{kind: "text", value: "42"}],
           pending_calls: [],
           error: nil
         }}
      end

      state =
        program_state(
          %{
            "model" => "gpt-5.6",
            "tools" => ptc_tools([market_tool(["programmatic"])]),
            "input" => []
          },
          runner
        )

      {state, [done_event], :continue} =
        observe!(state, %{
          "type" => "response.output_item.done",
          "sequence_number" => 4,
          "item" => program_call_item("text(42)")
        })

      assert done_event["item"]["type"] == "program"
      assert done_event["item"]["code"] == "text(42)"
      assert is_binary(done_event["item"]["fingerprint"])

      {_state, events, {:round, continuation_request}} =
        observe!(state, completed_event([program_call_item("text(42)")]))

      assert [output_event] = events
      assert output_event["item"]["type"] == "program_output"
      assert output_event["item"]["status"] == "completed"
      assert output_event["item"]["result"] == "42"

      [call, output] = Enum.take(continuation_request["input"], 2)
      assert call["name"] == "program"
      assert output["type"] == "function_call_output"
      assert output["output"] =~ "42"
    end

    test "a paused program finalizes with caller-tagged nested calls" do
      runner = fn _code, _bindings, _memo ->
        {:ok,
         %{
           status: :pending,
           output: [],
           pending_calls: [%{name: "market", arguments: %{"symbol" => "600519"}}],
           error: nil
         }}
      end

      state =
        program_state(
          %{
            "model" => "gpt-5.6",
            "tools" => ptc_tools([market_tool(["programmatic"])]),
            "input" => []
          },
          runner
        )

      {state, _events, :continue} =
        observe!(state, %{
          "type" => "response.output_item.done",
          "sequence_number" => 4,
          "item" => program_call_item("await tools.market({symbol:'600519'})")
        })

      {_state, events, {:terminal, outcome, :keep_upstream}} =
        observe!(
          state,
          completed_event([program_call_item("await tools.market({symbol:'600519'})")])
        )

      [nested_event, terminal] = events
      assert nested_event["item"]["type"] == "function_call"
      assert nested_event["item"]["call_id"] == "prog_1_c0"
      assert nested_event["item"]["caller"] == %{"type" => "program", "caller_id" => "prog_1"}

      output_types = Enum.map(terminal["response"]["output"], & &1["type"])
      assert output_types == ["program", "function_call"]
      assert Enum.map(outcome.public_items, & &1["type"]) == ["program", "function_call"]
    end
  end

  describe "pre-round resume" do
    defp resume_loop(input, program_run) do
      {:ok, provider_request, plan} =
        ToolSearch.plan(%{
          "model" => "gpt-5.6",
          "tools" => ptc_tools([market_tool(["programmatic"])]),
          "input" => input
        })

      StreamLoop.new(%{plan: plan, provider_request: provider_request, program_run: program_run})
    end

    defp resume_input(code) do
      fingerprint = ToolSearch.program_fingerprint(code, ["market"])

      [
        %{
          "type" => "program",
          "call_id" => "prog_1",
          "code" => code,
          "fingerprint" => fingerprint
        },
        %{
          "type" => "function_call",
          "call_id" => "prog_1_c0",
          "name" => "market",
          "arguments" => ~s({}),
          "caller" => %{"type" => "program", "caller_id" => "prog_1"}
        },
        %{
          "type" => "function_call_output",
          "call_id" => "prog_1_c0",
          "output" => ~s({"price":1700})
        }
      ]
    end

    test "a resumed program that completes hands control to the provider round" do
      runner = fn _code, _bindings, memo ->
        assert [%{"name" => "market", "output" => %{"price" => 1700}}] =
                 Enum.map(memo, &Map.take(&1, ["name", "output"]))

        {:ok,
         %{
           status: :completed,
           output: [%{kind: "text", value: "1700"}],
           pending_calls: [],
           error: nil
         }}
      end

      loop = resume_loop(resume_input("const d = await tools.market({}); text(d.price);"), runner)
      assert StreamLoop.pre_round?(loop)

      {:provider_round, [output_item], continuation_request, _loop} = StreamLoop.pre_round(loop)

      assert output_item["type"] == "program_output"
      assert output_item["status"] == "completed"

      outputs =
        Enum.filter(continuation_request["input"], &(&1["type"] == "function_call_output"))

      assert Enum.any?(outputs, &(&1["call_id"] == "prog_1"))
    end

    test "a resumed program that pauses again answers without a provider" do
      runner = fn _code, _bindings, _memo ->
        {:ok,
         %{
           status: :pending,
           output: [],
           pending_calls: [%{name: "market", arguments: %{"symbol" => "000001"}}],
           error: nil
         }}
      end

      loop =
        resume_loop(
          resume_input("await tools.market({}); await tools.market({symbol:'000001'});"),
          runner
        )

      {:respond, [nested], _loop} = StreamLoop.pre_round(loop)
      assert nested["type"] == "function_call"
      assert nested["call_id"] == "prog_1_c1"
      assert nested["caller"]["caller_id"] == "prog_1"
    end

    test "a fingerprint mismatch fails the program loudly" do
      runner = fn _code, _bindings, _memo -> raise "must not run" end

      input = [
        %{
          "type" => "program",
          "call_id" => "prog_1",
          "code" => "text(1)",
          "fingerprint" => "stale"
        },
        %{
          "type" => "function_call",
          "call_id" => "prog_1_c0",
          "name" => "market",
          "arguments" => ~s({}),
          "caller" => %{"type" => "program", "caller_id" => "prog_1"}
        },
        %{"type" => "function_call_output", "call_id" => "prog_1_c0", "output" => ~s({})}
      ]

      loop = resume_loop(input, runner)

      {:provider_round, [output_item], _continuation_request, _loop} = StreamLoop.pre_round(loop)
      assert output_item["status"] == "incomplete"
      assert output_item["result"] =~ "fingerprint"
    end
  end
end
