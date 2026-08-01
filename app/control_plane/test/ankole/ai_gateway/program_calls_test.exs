defmodule Ankole.AIGateway.ProgramCallsTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.ProgramExecution
  alias Ankole.AIGateway.ProgrammaticToolCalling, as: PTC
  alias Ankole.AIGateway.ToolContract.Descriptor
  alias Ankole.AIGateway.ToolSearch
  alias Ankole.AIGateway.ToolSearch.StreamLoop

  defp function_tool(name, callers, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "function",
        "name" => name,
        "description" => "#{name} function",
        "allowed_callers" => callers,
        "parameters" => %{"type" => "object", "properties" => %{}}
      },
      extra
    )
  end

  defp market_tool(callers, extra \\ %{}),
    do: function_tool("market", callers, extra)

  defp custom_tool(name, callers, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "custom",
        "name" => name,
        "description" => "#{name} custom tool",
        "allowed_callers" => callers,
        "format" => %{"type" => "text"}
      },
      extra
    )
  end

  defp ptc_tools(tools), do: tools ++ [%{"type" => "programmatic_tool_calling"}]

  defp request(tools, input \\ []) do
    %{"model" => "gpt-5.6", "tools" => ptc_tools(tools), "input" => input}
  end

  defp plan!(request) do
    assert {:ok, provider_request, %ToolSearch.Plan{} = plan} = ToolSearch.plan(request)
    {provider_request, plan}
  end

  defp loop!(request) do
    {provider_request, plan} = plan!(request)
    {StreamLoop.new(%{plan: plan, provider_request: provider_request}), provider_request, plan}
  end

  defp binding_names(%{ptc: %{program: %{bindings: bindings}}}),
    do: Enum.map(bindings, & &1.provider_name)

  defp program_call(call_id, code, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "function_call",
        "id" => "fc_#{call_id}",
        "name" => "program",
        "call_id" => call_id,
        "status" => "completed",
        "arguments" => Ankole.JSON.encode!(%{"code" => code})
      },
      extra
    )
  end

  defp search_call(call_id, path) do
    %{
      "type" => "function_call",
      "id" => "fc_#{call_id}",
      "name" => "tool_search",
      "call_id" => call_id,
      "status" => "completed",
      "arguments" => Ankole.JSON.encode!(%{"paths" => [path]})
    }
  end

  defp terminal_response(output) do
    %{
      "id" => "resp_provider",
      "object" => "response",
      "status" => "completed",
      "output" => output
    }
  end

  defp completed_outcome(value) do
    %{
      status: :completed,
      output: [%{kind: "text", value: value}],
      pending_calls: [],
      error: nil,
      error_code: nil
    }
  end

  defp pending_outcome(calls) do
    %{
      status: :pending,
      output: [],
      pending_calls: calls,
      error: nil,
      error_code: nil
    }
  end

  defp result(call_id, outcome), do: %{call_id: call_id, outcome: outcome}

  defp with_limits(loop, overrides),
    do: %{loop | limits: Map.merge(loop.limits, Map.new(overrides))}

  defp caller(program_id), do: %{"type" => "program", "caller_id" => program_id}

  defp program_item(call_id, code, bindings, extra \\ %{}) do
    Map.merge(
      %{
        "type" => "program",
        "call_id" => call_id,
        "code" => code,
        "fingerprint" => PTC.fingerprint(code, bindings),
        "status" => "completed"
      },
      extra
    )
  end

  defp rewrite_fingerprint_payload(fingerprint, rewrite) do
    prefix = "ankole_ptc_v1."
    encoded = String.replace_prefix(fingerprint, prefix, "")
    payload = encoded |> Base.url_decode64!(padding: false) |> Ankole.JSON.decode!()
    prefix <> Base.url_encode64(Ankole.JSON.encode!(rewrite.(payload)), padding: false)
  end

  defp function_pair(program_id, call_id, name, arguments, output) do
    scope = caller(program_id)

    [
      %{
        "type" => "function_call",
        "call_id" => call_id,
        "name" => name,
        "arguments" => Ankole.JSON.encode!(arguments),
        "status" => "completed",
        "caller" => scope
      },
      %{
        "type" => "function_call_output",
        "call_id" => call_id,
        "output" => output,
        "caller" => scope
      }
    ]
  end

  defp custom_pair(program_id, call_id, name, input, output) do
    scope = caller(program_id)

    [
      %{
        "type" => "custom_tool_call",
        "call_id" => call_id,
        "name" => name,
        "input" => input,
        "status" => "completed",
        "caller" => scope
      },
      %{
        "type" => "custom_tool_call_output",
        "call_id" => call_id,
        "output" => output,
        "caller" => scope
      }
    ]
  end

  describe "PTC contract planning" do
    test "a pure JavaScript declaration synthesizes program with zero bindings" do
      {provider_request, plan} = plan!(request([]))

      assert binding_names(plan) == []
      assert Enum.map(provider_request["tools"], & &1["name"]) == ["program"]

      [program] = provider_request["tools"]
      assert program["description"] =~ "matching direct tool declarations: []"
      assert program["description"] =~ "programmatic-only bindings and contracts: []"
      assert program["description"] =~ ~s|tools["<name>"](args)|

      assert {:ok, job} = PTC.job(plan.ptc, program_call("prog_js", "text(42)"))
      assert job.binding_names == []
      assert job.bindings == []
      assert is_binary(job.fingerprint)
    end

    test "program keeps immutable descriptors instead of collapsing contracts to names" do
      output_schema = %{
        "type" => "object",
        "required" => ["price"],
        "properties" => %{"price" => %{"type" => "number"}},
        "additionalProperties" => false
      }

      {provider_request, plan} =
        plan!(
          request([
            market_tool(["direct", "programmatic"], %{
              "strict" => true,
              "output_schema" => output_schema
            }),
            function_tool("weather", ["direct"])
          ])
        )

      assert [
               %Descriptor{
                 provider_name: "market",
                 type: "function",
                 allowed_callers: ["direct", "programmatic"],
                 output_schema: ^output_schema,
                 strict: true
               }
             ] = plan.ptc.program.bindings

      assert Enum.map(provider_request["tools"], & &1["name"]) == [
               "market",
               "weather",
               "program"
             ]

      refute Enum.any?(provider_request["tools"], &Map.has_key?(&1, "allowed_callers"))
      [program] = Enum.filter(provider_request["tools"], &(&1["name"] == "program"))
      assert program["description"] =~ ~s|matching direct tool declarations: ["market"]|
      refute program["description"] =~ "output_schema"

      {_provider_request, programmatic_only_plan} =
        plan!(
          request([
            market_tool(["programmatic"], %{
              "strict" => true,
              "output_schema" => output_schema
            })
          ])
        )

      assert PTC.provider_tool(programmatic_only_plan.ptc)["description"] =~ "output_schema"

      {_provider_request, changed_plan} =
        plan!(
          request([
            market_tool(["direct", "programmatic"], %{
              "strict" => true,
              "output_schema" => Map.put(output_schema, "required", [])
            })
          ])
        )

      refute PTC.fingerprint("text(1)", plan.ptc.program.bindings) ==
               PTC.fingerprint("text(1)", changed_plan.ptc.program.bindings)
    end

    test "responses-lite carrier receives the same descriptor-backed program" do
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
      assert binding_names(plan) == ["market"]

      assert Enum.map(hd(provider_request["input"])["tools"], & &1["name"]) == [
               "market",
               "program"
             ]
    end

    test "deferred namespace contracts join an already available pure-JS program only after loading" do
      namespace = %{
        "type" => "namespace",
        "name" => "mcp__finance",
        "description" => "Financial data tools",
        "tools" => [
          market_tool(["direct", "programmatic"], %{"defer_loading" => true})
        ]
      }

      {provider_request, plan} =
        plan!(request([namespace, %{"type" => "tool_search", "execution" => "server"}]))

      assert binding_names(plan) == []
      assert Enum.map(provider_request["tools"], & &1["name"]) == ["tool_search", "program"]

      assert {:ok, [loaded]} = ToolSearch.search_paths(plan, ["mcp__finance"])

      assert {:ok, loaded_plan, provider_tools} =
               ToolSearch.load_tools(plan, provider_request["tools"], [loaded])

      assert binding_names(loaded_plan) == ["mcp__finance__market"]

      assert Enum.sort(Enum.map(provider_tools, & &1["name"])) == [
               "mcp__finance__market",
               "program",
               "tool_search"
             ]

      assert {:ok, nested} =
               PTC.nested_call(
                 "prog_1",
                 0,
                 %{name: "mcp__finance__market", arguments: %{}},
                 loaded_plan.ptc.program.bindings
               )

      assert nested["namespace"] == "mcp__finance"
      assert nested["name"] == "market"
    end

    test "allowed_callers alone does not opt a request into PTC" do
      {provider_request, plan} =
        plan!(%{
          "model" => "gpt-5.6",
          "tools" => [market_tool(["direct", "programmatic"])],
          "input" => []
        })

      assert plan.ptc.program == nil
      assert Enum.map(provider_request["tools"], & &1["name"]) == ["market"]
      refute Map.has_key?(hd(provider_request["tools"]), "allowed_callers")
    end
  end

  describe "history replay and program resumption" do
    test "settled program history becomes one provider call/output pair" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, initial_plan} = plan!(request(tools))
      code = "text(1)"

      input = [
        program_item("prog_1", code, initial_plan.ptc.program.bindings),
        %{
          "type" => "program_output",
          "call_id" => "prog_1",
          "status" => "completed",
          "result" => "1"
        }
      ]

      {provider_request, plan} = plan!(request(tools, input))
      assert plan.ptc.resumes == []

      assert [call, output] = provider_request["input"]
      assert call["type"] == "function_call"
      assert call["name"] == "program"
      assert call["call_id"] == "prog_1"
      assert output["type"] == "function_call_output"
      assert output["call_id"] == "prog_1"
      assert output["output"] =~ "completed"
    end

    test "settled program history remains readable after the current PTC surface disappears" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, initial_plan} = plan!(request(tools))
      code = "const quote = await tools.market({}); text(quote.price);"

      input =
        [program_item("prog_old", code, initial_plan.ptc.program.bindings)] ++
          function_pair("prog_old", "prog_old_c0", "market", %{}, ~s({"price":1700})) ++
          [
            %{
              "type" => "program_output",
              "call_id" => "prog_old",
              "status" => "completed",
              "result" => "1700"
            }
          ]

      current_request = %{"model" => "gpt-5.6", "tools" => [], "input" => input}

      assert {:ok, provider_request, plan} = ToolSearch.plan(current_request)
      refute plan.ptc.enabled?
      assert plan.ptc.program == nil
      assert provider_request["tools"] == []

      assert [call, output] = provider_request["input"]
      assert call["type"] == "function_call"
      assert call["name"] == "program"
      assert call["call_id"] == "prog_old"
      assert output["type"] == "function_call_output"
      assert output["call_id"] == "prog_old"
      assert output["output"] =~ "completed"
    end

    test "unsettled program history still requires the current PTC declaration" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, initial_plan} = plan!(request(tools))
      code = "const quote = await tools.market({}); text(quote.price);"

      current_request = %{
        "model" => "gpt-5.6",
        "tools" => [],
        "input" => [program_item("prog_unsettled", code, initial_plan.ptc.program.bindings)]
      }

      assert {:error, {:invalid_program, :declaration_missing}} =
               ToolSearch.plan(current_request)
    end

    test "multiple unsettled programs are frozen and resumed together" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, initial_plan} = plan!(request(tools))
      bindings = initial_plan.ptc.program.bindings

      input =
        [program_item("prog_a", "text('a')", bindings)] ++
          function_pair("prog_a", "prog_a_c0", "market", %{"symbol" => "A"}, "raw-a") ++
          [program_item("prog_b", "text('b')", bindings)] ++
          function_pair("prog_b", "prog_b_c0", "market", %{"symbol" => "B"}, "raw-b")

      {loop, provider_request, plan} = loop!(request(tools, input))

      assert Enum.map(plan.ptc.resumes, & &1.call_id) == ["prog_a", "prog_b"]
      assert Enum.map(provider_request["input"], & &1["name"]) == ["program", "program"]
      assert StreamLoop.initial_local_effect?(loop)

      assert {:ok, jobs, context, loop} = StreamLoop.take_initial_local_effect(loop)
      assert Enum.map(jobs, & &1.call_id) == ["prog_a", "prog_b"]
      assert Enum.map(jobs, & &1.binding_names) == [["market"], ["market"]]
      assert Enum.map(jobs, &hd(&1.memo)["output"]) == ["raw-a", "raw-b"]
      refute StreamLoop.initial_local_effect?(loop)

      outcomes = [
        result("prog_a", pending_outcome([%{name: "market", arguments: %{"next" => "A"}}])),
        result("prog_b", pending_outcome([%{name: "market", arguments: %{"next" => "B"}}]))
      ]

      assert {:finalize, [], nested, _loop} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert Enum.map(nested, & &1["call_id"]) == ["prog_a_c1", "prog_b_c1"]
      assert Enum.map(nested, &get_in(&1, ["caller", "caller_id"])) == ["prog_a", "prog_b"]
    end

    test "null function arguments survive pause and history replay exactly" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, initial_plan} = plan!(request(tools))
      code = "const quote = await tools.market(null); text(quote.price);"

      assert {:ok, nested} =
               PTC.nested_call(
                 "prog_null",
                 0,
                 %{name: "market", arguments: nil},
                 initial_plan.ptc.program.bindings
               )

      assert nested["arguments"] == "null"

      input =
        [program_item("prog_null", code, initial_plan.ptc.program.bindings)] ++
          function_pair("prog_null", "prog_null_c0", "market", nil, ~s({"price":1700}))

      {_request, replay_plan} = plan!(request(tools, input))
      assert [round] = replay_plan.ptc.resumes
      assert hd(round.memo)["arguments"] == nil
    end

    test "declared output_schema opts into JSON decoding while undeclared output stays raw" do
      schema = %{
        "type" => "object",
        "required" => ["price"],
        "properties" => %{"price" => %{"type" => "number"}},
        "additionalProperties" => false
      }

      schema_tool = market_tool(["programmatic"], %{"output_schema" => schema})
      {_provider_request, schema_plan} = plan!(request([schema_tool]))
      code = "const quote = await tools.market({}); text(quote.price);"

      schema_input =
        [program_item("prog_schema", code, schema_plan.ptc.program.bindings)] ++
          function_pair(
            "prog_schema",
            "prog_schema_c0",
            "market",
            %{},
            ~s({"price":1700})
          )

      {_request, replay_plan} = plan!(request([schema_tool], schema_input))
      assert [round] = replay_plan.ptc.resumes
      assert hd(round.memo)["output"] == %{"price" => 1700}

      raw_tool = market_tool(["programmatic"])
      {_provider_request, raw_plan} = plan!(request([raw_tool]))

      raw_input =
        [program_item("prog_raw", code, raw_plan.ptc.program.bindings)] ++
          function_pair("prog_raw", "prog_raw_c0", "market", %{}, ~s({"price":1700}))

      {_request, raw_replay_plan} = plan!(request([raw_tool], raw_input))
      assert [raw_round] = raw_replay_plan.ptc.resumes
      assert hd(raw_round.memo)["output"] == ~s({"price":1700})
    end

    test "the gateway decodes declared JSON without duplicating the tool owner's schema validator" do
      schema = %{
        "type" => "object",
        "required" => ["price"],
        "properties" => %{"price" => %{"type" => "number"}}
      }

      tool = market_tool(["programmatic"], %{"output_schema" => schema})
      {_provider_request, plan} = plan!(request([tool]))
      code = "const quote = await tools.market({}); text(quote.price);"

      input =
        [program_item("prog_bad", code, plan.ptc.program.bindings)] ++
          function_pair("prog_bad", "prog_bad_c0", "market", %{}, ~s({"price":"bad"}))

      {_request, replay_plan} = plan!(request([tool], input))
      assert [round] = replay_plan.ptc.resumes
      assert hd(round.memo)["output"] == %{"price" => "bad"}
    end

    test "custom output_schema decodes replay and preserves text input" do
      schema = %{
        "type" => "object",
        "required" => ["stdout"],
        "properties" => %{"stdout" => %{"type" => "string"}}
      }

      tool = custom_tool("shell", ["programmatic"], %{"output_schema" => schema})
      {_provider_request, plan} = plan!(request([tool]))
      code = "const result = await tools.shell('pwd'); text(result.stdout);"

      input =
        [program_item("prog_custom", code, plan.ptc.program.bindings)] ++
          custom_pair("prog_custom", "prog_custom_c0", "shell", "pwd", ~s({"stdout":"/tmp"}))

      {_request, replay_plan} = plan!(request([tool], input))
      assert [round] = replay_plan.ptc.resumes

      assert hd(round.memo) == %{
               "name" => "shell",
               "arguments" => "pwd",
               "output" => %{"stdout" => "/tmp"}
             }
    end
  end

  describe "asynchronous terminal program execution" do
    test "completed programs continue the provider round through prepare/complete" do
      {loop, _provider_request, _plan} =
        loop!(request([market_tool(["programmatic"])]))

      call = program_call("prog_1", "text(42)")

      assert {:local, [job], context, loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([call])
               )

      assert job.code == "text(42)"
      assert job.binding_names == ["market"]
      assert job.memo == []

      outcomes =
        ProgramExecution.run_jobs([job], fn code, binding_names, memo ->
          assert code == "text(42)"
          assert binding_names == ["market"]
          assert memo == []
          {:ok, completed_outcome("42")}
        end)

      assert {:round, continuation_request, [output], loop} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert loop.rounds == 1
      assert output["type"] == "program_output"
      assert output["status"] == "completed"
      assert output["result"] == "42"

      assert [provider_call, provider_output] =
               Enum.take(continuation_request["input"], 2)

      assert provider_call["name"] == "program"
      assert provider_output["type"] == "function_call_output"
      assert provider_output["output"] =~ "42"
    end

    test "paused custom programs emit custom_tool_call with caller ownership" do
      {loop, _provider_request, _plan} =
        loop!(request([custom_tool("shell", ["programmatic"])]))

      call = program_call("prog_custom", "await tools.shell('pwd')")

      assert {:local, [_job], context, loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([call])
               )

      outcomes = [result("prog_custom", pending_outcome([%{name: "shell", arguments: "pwd"}]))]

      assert {:finalize, [public_program], [nested], _loop} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert public_program["type"] == "program"
      assert nested["type"] == "custom_tool_call"
      assert nested["name"] == "shell"
      assert nested["input"] == "pwd"
      assert nested["call_id"] == "prog_custom_c0"
      assert nested["caller"] == caller("prog_custom")
    end

    test "same-terminal Tool Search cannot widen a frozen program job" do
      late_tool =
        function_tool("late_tool", ["programmatic"], %{
          "description" => "late_tool deferred capability",
          "defer_loading" => true
        })

      tools = [
        market_tool(["programmatic"]),
        late_tool,
        %{"type" => "tool_search", "execution" => "server"}
      ]

      {loop, _provider_request, initial_plan} = loop!(request(tools))
      assert binding_names(initial_plan) == ["market"]

      output = [
        search_call("search_1", "late_tool"),
        program_call("prog_frozen", "await tools.market({})")
      ]

      assert {:local, [job], context, loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response(output)
               )

      assert job.binding_names == ["market"]
      assert job.fingerprint == PTC.fingerprint(job.code, job.bindings)
      assert binding_names(loop.plan) == ["market", "late_tool"]

      outcomes = [
        result(
          "prog_frozen",
          pending_outcome([%{name: "late_tool", arguments: %{}}])
        )
      ]

      assert {:round, _request, extras, _loop} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert Enum.map(extras, & &1["type"]) == ["tool_search_output", "program_output"]
      program_output = List.last(extras)
      assert program_output["status"] == "incomplete"
      assert program_output["result"] =~ "program_tool_not_allowed"
      refute Enum.any?(extras, &(&1["type"] == "function_call" and &1["name"] == "late_tool"))
    end

    test "same-terminal search preserves the old binding snapshot across a stateless resume" do
      late_tool =
        function_tool("late_tool", ["programmatic"], %{
          "description" => "late_tool deferred capability",
          "defer_loading" => true
        })

      tools = [
        market_tool(["programmatic"]),
        late_tool,
        %{"type" => "tool_search", "execution" => "server"}
      ]

      {loop, _provider_request, initial_plan} = loop!(request(tools))
      code = "const quote = await tools.market({}); text(quote);"

      assert binding_names(initial_plan) == ["market"]

      assert {:local, [job], context, widened_loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([
                   search_call("search_snapshot", "late_tool"),
                   program_call("prog_snapshot", code)
                 ])
               )

      assert job.binding_names == ["market"]
      assert binding_names(widened_loop.plan) == ["market", "late_tool"]

      outcomes = [
        result(
          "prog_snapshot",
          pending_outcome([%{name: "market", arguments: %{"symbol" => "ETH"}}])
        )
      ]

      assert {:finalize, [search, program], [search_output, nested], _loop} =
               StreamLoop.complete_local_effect(widened_loop, context, outcomes)

      assert search["type"] == "tool_search_call"
      assert program["type"] == "program"
      assert program["fingerprint"] == job.fingerprint
      assert search_output["type"] == "tool_search_output"
      assert nested["name"] == "market"

      nested_output = %{
        "type" => "function_call_output",
        "call_id" => nested["call_id"],
        "output" => "raw-market-result",
        "caller" => nested["caller"]
      }

      history = [search, program, search_output, nested, nested_output]
      {resume_loop, _provider_request, resume_plan} = loop!(request(tools, history))

      assert binding_names(resume_plan) == ["market", "late_tool"]
      assert [round] = resume_plan.ptc.resumes
      assert Enum.map(round.bindings, & &1.provider_name) == ["market"]
      assert hd(round.memo)["output"] == "raw-market-result"

      assert {:ok, [resume_job], _context, _loop} =
               StreamLoop.take_initial_local_effect(resume_loop)

      assert resume_job.binding_names == ["market"]
      assert resume_job.fingerprint == program["fingerprint"]
      refute Map.has_key?(resume_job, :preflight_outcome)
    end

    test "versioned fingerprints restore order and reject malformed binding snapshots" do
      tools = [
        market_tool(["programmatic"]),
        function_tool("weather", ["programmatic"])
      ]

      {_provider_request, plan} = plan!(request(tools))
      code = "text('snapshot')"
      fingerprint = PTC.fingerprint(code, plan.ptc.program.bindings)

      resume = %{
        call_id: "prog_token",
        code: code,
        fingerprint: fingerprint,
        memo: []
      }

      reordered_ptc = %{
        plan.ptc
        | program: %{
            plan.ptc.program
            | bindings: Enum.reverse(plan.ptc.program.bindings)
          }
      }

      assert {:ok, restored} = PTC.resume_job(reordered_ptc, resume)
      assert restored.binding_names == ["market", "weather"]

      duplicate =
        rewrite_fingerprint_payload(fingerprint, fn payload ->
          Map.put(payload, "bindings", ["market", "market"])
        end)

      missing_ptc = %{plan.ptc | program: %{plan.ptc.program | bindings: []}}
      [market | _] = plan.ptc.program.bindings

      non_programmatic_ptc = %{
        plan.ptc
        | program: %{
            plan.ptc.program
            | bindings: [%{market | allowed_callers: ["direct"]}]
          }
      }

      invalid_cases = [
        {plan.ptc, %{resume | fingerprint: "0123456789abcdef0123456789abcdef"}},
        {plan.ptc, %{resume | fingerprint: "ankole_ptc_v1.not-base64!"}},
        {plan.ptc, %{resume | fingerprint: String.duplicate("x", 16_385)}},
        {plan.ptc, %{resume | fingerprint: duplicate}},
        {missing_ptc, resume},
        {non_programmatic_ptc, resume}
      ]

      for {invalid_ptc, invalid_round} <- invalid_cases do
        assert {:error, {:program_fingerprint_mismatch, "prog_token"}} =
                 PTC.resume_job(invalid_ptc, invalid_round)
      end
    end

    test "changed descriptor fingerprint becomes a preflight failure and never calls the runner" do
      old_tool =
        market_tool(["programmatic"], %{
          "output_schema" => %{"type" => "object", "required" => ["price"]}
        })

      {_provider_request, old_plan} = plan!(request([old_tool]))
      code = "text(1)"
      history = [program_item("prog_stale", code, old_plan.ptc.program.bindings)]

      changed_tool =
        market_tool(["programmatic"], %{
          "output_schema" => %{"type" => "object", "required" => []}
        })

      {loop, _provider_request, _changed_plan} = loop!(request([changed_tool], history))
      assert {:ok, [job], context, loop} = StreamLoop.take_initial_local_effect(loop)
      assert job.preflight_outcome.error_code == "program_contract_changed"

      outcomes =
        ProgramExecution.run_jobs([job], fn _code, _bindings, _memo ->
          flunk("preflight failures must not enter the native runner")
        end)

      assert {:round, _request, [output], _loop} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert output["status"] == "incomplete"
      assert output["result"] =~ "program_fingerprint_mismatch"
    end
  end

  describe "fail-closed lifecycle and shared budgets" do
    test "partial provider programs are never admitted as jobs" do
      {loop, _provider_request, _plan} = loop!(request([]))

      partial =
        program_call("prog_partial", "text(1)", %{
          "status" => "in_progress"
        })

      assert {:finalize, [public], [], loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([partial])
               )

      assert public["type"] == "program"
      refute Map.has_key?(public, "fingerprint")
      assert StreamLoop.incomplete_reason(loop) == "incomplete_call_item"
    end

    test "duplicate provider program call ids terminate incomplete without execution" do
      {loop, _provider_request, _plan} = loop!(request([]))
      calls = [program_call("prog_dup", "text(1)"), program_call("prog_dup", "text(2)")]

      assert {:finalize, public, [], loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response(calls)
               )

      assert Enum.all?(public, &(&1["type"] == "program"))
      assert StreamLoop.incomplete_reason(loop) == "duplicate_program_call_id"
    end

    test "history rejects duplicate, orphan, partial, and unanswered aggregates" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, plan} = plan!(request(tools))
      root = program_item("prog_1", "text(1)", plan.ptc.program.bindings)

      cases = [
        {[root, root], {:duplicate_program_call_id, "prog_1"}},
        {[
           %{
             "type" => "program_output",
             "call_id" => "missing",
             "status" => "completed",
             "result" => "x"
           }
         ], {:orphan_program_output, "missing"}},
        {[Map.put(root, "status", "in_progress")], {:incomplete_program, "prog_1"}},
        {[
           root,
           hd(function_pair("prog_1", "prog_1_c0", "market", %{}, "unused"))
         ], {:program_calls_unanswered, "prog_1"}},
        {[
           root,
           %{
             "type" => "function_call_output",
             "call_id" => "missing",
             "output" => "x",
             "caller" => caller("prog_1")
           }
         ], {:orphan_program_call_output, "prog_1", "missing"}}
      ]

      for {input, expected} <- cases do
        assert {:error, {:invalid_program, ^expected}} = ToolSearch.plan(request(tools, input))
      end
    end

    test "history replay preserves the first error when it stops early" do
      input = [
        %{
          "type" => "program_output",
          "call_id" => "first",
          "status" => "completed",
          "result" => "first"
        },
        %{
          "type" => "program_output",
          "call_id" => "second",
          "status" => "completed",
          "result" => "second"
        }
      ]

      assert {:error, {:invalid_program, {:orphan_program_output, "first"}}} =
               ToolSearch.plan(request([], input))
    end

    test "search and program continuations consume one shared round budget" do
      late_tool =
        function_tool("late_tool", ["programmatic"], %{
          "description" => "late_tool deferred capability",
          "defer_loading" => true
        })

      tools = [
        market_tool(["programmatic"]),
        late_tool,
        %{"type" => "tool_search", "execution" => "server"}
      ]

      {loop, _provider_request, _plan} = loop!(request(tools))
      loop = %{loop | rounds: 15}

      call = program_call("prog_budget", "text(1)")

      assert {:local, [_job], context, loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([call])
               )

      assert {:round, _request, [_output], loop} =
               StreamLoop.complete_local_effect(
                 loop,
                 context,
                 [result("prog_budget", completed_outcome("1"))]
               )

      assert loop.rounds == 16

      assert {:finalize, [search], [], exhausted} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([search_call("search_budget", "late_tool")])
               )

      assert search["type"] == "tool_search_call"
      assert StreamLoop.incomplete_reason(exhausted) == "tool_loop_rounds_exhausted"
    end

    test "program continuation tool budget includes prior memo calls" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, initial_plan} = plan!(request(tools))
      code = "for (;;) await tools.market({})"
      root = program_item("prog_limit", code, initial_plan.ptc.program.bindings)

      history =
        Enum.flat_map(0..255, fn index ->
          function_pair(
            "prog_limit",
            "prog_limit_c#{index}",
            "market",
            %{"index" => index},
            "ok-#{index}"
          )
        end)

      {loop, _provider_request, plan} = loop!(request(tools, [root | history]))
      assert [round] = plan.ptc.resumes
      assert length(round.memo) == 256

      assert {:ok, [_job], context, loop} = StreamLoop.take_initial_local_effect(loop)

      outcomes = [
        result("prog_limit", pending_outcome([%{name: "market", arguments: %{"index" => 256}}]))
      ]

      assert {:round, _request, [output], _loop} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert output["type"] == "program_output"
      assert output["status"] == "incomplete"
      assert output["result"] =~ "program exceeded 256 nested tool calls"
    end

    test "initial terminal history is bounded by both item count and encoded bytes" do
      {loop, _provider_request, _plan} = loop!(request([]))

      too_many =
        Enum.map(1..3, fn index ->
          %{"type" => "message", "role" => "assistant", "content" => "item-#{index}"}
        end)

      item_limited = with_limits(loop, provider_history_items: 2)

      assert {:finalize, ^too_many, [], item_limited} =
               StreamLoop.intercept_terminal(
                 item_limited,
                 "response.completed",
                 terminal_response(too_many)
               )

      assert StreamLoop.incomplete_reason(item_limited) ==
               "provider_history_item_limit_exceeded"

      large = [
        %{"type" => "message", "role" => "assistant", "content" => String.duplicate("x", 256)}
      ]

      byte_limited = with_limits(loop, provider_history_bytes: 128)

      assert {:finalize, ^large, [], byte_limited} =
               StreamLoop.intercept_terminal(
                 byte_limited,
                 "response.completed",
                 terminal_response(large)
               )

      assert StreamLoop.incomplete_reason(byte_limited) ==
               "provider_history_byte_limit_exceeded"
    end

    test "search output capacity is checked atomically before loading or continuing" do
      late_tool =
        function_tool("late_tool", ["programmatic"], %{
          "description" => "late_tool deferred capability",
          "defer_loading" => true
        })

      tools = [late_tool, %{"type" => "tool_search", "execution" => "server"}]
      {loop, _provider_request, _plan} = loop!(request(tools))
      loop = with_limits(loop, provider_history_items: 1)
      call = search_call("search_capacity", "late_tool")

      assert {:finalize, [public], [], limited} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([call])
               )

      assert public["type"] == "tool_search_call"
      assert limited.plan.loaded_names == MapSet.new()

      assert StreamLoop.incomplete_reason(limited) ==
               "provider_history_item_limit_exceeded"
    end

    test "a later invalid search path cannot partially commit an earlier search" do
      first =
        function_tool("first_tool", ["direct"], %{
          "defer_loading" => true
        })

      second =
        function_tool("second_tool", ["direct"], %{
          "defer_loading" => true
        })

      tools = [first, second, %{"type" => "tool_search", "execution" => "server"}]
      {loop, _provider_request, _plan} = loop!(request(tools))

      output = [
        search_call("search_valid", "first_tool"),
        search_call("search_invalid", "missing_tool")
      ]

      assert {:finalize, public, [], failed} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response(output)
               )

      assert Enum.map(public, & &1["type"]) == ["tool_search_call", "tool_search_call"]
      assert Enum.all?(public, &is_nil(&1["call_id"]))
      assert failed.plan.loaded_names == MapSet.new()
      assert StreamLoop.incomplete_reason(failed) == "unknown_tool_search_path"
    end

    test "legacy query arguments are replay-only and rejected for new server calls" do
      late_tool =
        function_tool("late_tool", ["direct"], %{
          "defer_loading" => true
        })

      tools = [late_tool, %{"type" => "tool_search", "execution" => "server"}]
      {loop, _provider_request, _plan} = loop!(request(tools))

      call =
        search_call("search_legacy", "late_tool")
        |> Map.put("arguments", Ankole.JSON.encode!(%{"query" => "late_tool"}))

      assert {:finalize, [public], [], failed} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([call])
               )

      assert public["arguments"] == %{"query" => "late_tool"}
      assert failed.plan.loaded_names == MapSet.new()
      assert StreamLoop.incomplete_reason(failed) == "invalid_tool_search_arguments"
    end

    test "program output byte overflow finalizes incomplete instead of opening a provider round" do
      {loop, _provider_request, _plan} = loop!(request([]))
      call = program_call("prog_large", "text('large')")

      reservation =
        PTC.downstream_output("prog_large", %{
          status: :failed,
          output: [],
          pending_calls: [],
          error: "",
          error_code: "program_output_reserved"
        })

      byte_limit = byte_size(Ankole.JSON.encode!([call, reservation])) + 32
      loop = with_limits(loop, provider_history_bytes: byte_limit)

      assert {:local, [_job], context, loop} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response([call])
               )

      outcomes = [result("prog_large", completed_outcome(String.duplicate("x", byte_limit)))]

      assert {:finalize, [_program], [output], limited} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert output["type"] == "program_output"

      assert StreamLoop.incomplete_reason(limited) ==
               "provider_history_byte_limit_exceeded"
    end

    test "a resumed program reserves its provider output slot before native execution" do
      tools = [market_tool(["programmatic"])]
      {_provider_request, initial_plan} = plan!(request(tools))
      root = program_item("prog_preflight", "text(1)", initial_plan.ptc.program.bindings)
      {loop, provider_request, _plan} = loop!(request(tools, [root]))
      assert length(provider_request["input"]) == 1
      loop = with_limits(loop, provider_history_items: 1)

      assert {:ok, [job], context, loop} = StreamLoop.take_initial_local_effect(loop)
      assert job.preflight_outcome.error_code == "program_admission_failed"

      outcomes =
        ProgramExecution.run_jobs([job], fn _code, _bindings, _memo ->
          flunk("history admission failure must not enter the native runner")
        end)

      assert {:finalize, [], [output], limited} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert output["status"] == "incomplete"

      assert StreamLoop.incomplete_reason(limited) ==
               "provider_history_item_limit_exceeded"
    end

    test "top-level program batch is rejected before search or program effects" do
      late_tool =
        function_tool("late_tool", ["programmatic"], %{
          "description" => "late_tool deferred capability",
          "defer_loading" => true
        })

      tools = [late_tool, %{"type" => "tool_search", "execution" => "server"}]
      {loop, _provider_request, _plan} = loop!(request(tools))
      loop = with_limits(loop, top_level_programs: 2)

      output = [
        search_call("search_batch", "late_tool"),
        program_call("prog_batch_1", "text(1)"),
        program_call("prog_batch_2", "text(2)"),
        program_call("prog_batch_3", "text(3)")
      ]

      assert {:finalize, public, [], limited} =
               StreamLoop.intercept_terminal(
                 loop,
                 "response.completed",
                 terminal_response(output)
               )

      assert Enum.map(public, & &1["type"]) == [
               "tool_search_call",
               "program",
               "program",
               "program"
             ]

      assert limited.plan.loaded_names == MapSet.new()
      assert StreamLoop.incomplete_reason(limited) == "program_batch_limit_exceeded"
    end

    test "an invalid resume batch becomes preflight failures without native work" do
      {_provider_request, initial_plan} = plan!(request([]))
      bindings = initial_plan.ptc.program.bindings

      roots =
        Enum.map(1..3, fn index ->
          program_item("prog_pre_batch_#{index}", "text(#{index})", bindings)
        end)

      {loop, _provider_request, _plan} = loop!(request([], roots))
      loop = with_limits(loop, top_level_programs: 2)

      assert {:ok, jobs, context, loop} = StreamLoop.take_initial_local_effect(loop)
      assert length(jobs) == 3
      assert Enum.all?(jobs, &(&1.preflight_outcome.error_code == "program_admission_failed"))

      outcomes =
        ProgramExecution.run_jobs(jobs, fn _code, _bindings, _memo ->
          flunk("over-limit resume batches must not enter the native runner")
        end)

      assert {:finalize, [], outputs, limited} =
               StreamLoop.complete_local_effect(loop, context, outcomes)

      assert length(outputs) == 3
      assert Enum.all?(outputs, &(&1["status"] == "incomplete"))
      assert StreamLoop.incomplete_reason(limited) == "program_batch_limit_exceeded"
    end
  end
end
