defmodule Ankole.AIGateway.ResponsesToolDispatchTest do
  use Ankole.AIGatewayCase

  import Ankole.AIGateway.ResponseFixtures

  alias Ankole.AIGateway.CredentialPool

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.Repo

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "first-party OpenAI preserves PTC tools whose execution owner is native" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_native_ptc_tools",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_responses_provider!(agent.uid, base_url, "openai-native-ptc-tools")

    tools = [
      %{
        "type" => "mcp",
        "server_label" => "inventory",
        "server_url" => "https://mcp.example.test",
        "require_approval" => "never",
        "allowed_callers" => ["programmatic"]
      },
      %{"type" => "apply_patch", "allowed_callers" => ["programmatic"]},
      %{"type" => "shell", "allowed_callers" => ["programmatic"]},
      %{
        "type" => "code_interpreter",
        "container" => %{"type" => "auto"},
        "allowed_callers" => ["programmatic"]
      },
      %{"type" => "programmatic_tool_calling"}
    ]

    assert {:ok, %{body: %{"id" => "resp_native_ptc_tools"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Run the native program.",
               "tools" => tools,
               "max_tool_calls" => 1
             })

    assert_receive {:gateway_request, request}
    assert request.body["tools"] == tools
    assert request.body["max_tool_calls"] == 1
  end

  test "first-party OpenAI preserves the native Codex collaboration schema" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_native_collaboration_schema",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_responses_provider!(
      agent.uid,
      base_url,
      "openai-native-collaboration-schema"
    )

    exec_description =
      "Run one command.\n\nexec tool declaration:\n```ts\n" <>
        "declare const tools: { exec_command(args: { cmd: string }): Promise<unknown>; };\n```"

    tools = [
      %{
        "type" => "namespace",
        "name" => "collaboration",
        "description" => "Tools for spawning and managing sub-agents.",
        "tools" => [
          %{
            "type" => "function",
            "name" => "followup_task",
            "description" =>
              "Send a follow-up task to an existing non-root target agent and trigger a turn if it is idle. If the target is already running, deliver the task promptly at message boundaries while sampling, or after the pending tool call completes.",
            "strict" => false,
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{
                  "type" => "string",
                  "description" => "Message text to send to the target agent.",
                  "encrypted" => true
                },
                "target" => %{
                  "type" => "string",
                  "description" =>
                    "Agent id or canonical task name to send a follow-up task to (from spawn_agent)."
                }
              },
              "required" => ["target", "message"],
              "additionalProperties" => false
            }
          }
        ]
      },
      %{
        "type" => "function",
        "name" => "exec_command",
        "description" => exec_description,
        "parameters" => %{
          "type" => "object",
          "properties" => %{"cmd" => %{"type" => "string"}},
          "required" => ["cmd"]
        }
      }
    ]

    assert {:ok, %{body: %{"id" => "resp_native_collaboration_schema"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Delegate the next step.",
               "tools" => tools
             })

    assert_receive {:gateway_request, request}
    assert request.body["tools"] == tools
    refute Map.has_key?(request.body, "__ankole_native_encrypted_tool_fields")
  end

  test "Codex preserves encrypted tool fields through openai-compatible Responses" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_compatible_codex_schema",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-codex-schema"
    )

    tools = [
      %{
        "type" => "namespace",
        "name" => "collaboration",
        "description" => "Tools for spawning and managing sub-agents.",
        "tools" => [
          %{
            "type" => "function",
            "name" => "followup_task",
            "description" => "Send a follow-up task to an existing agent.",
            "strict" => false,
            "parameters" => %{
              "type" => "object",
              "properties" => %{
                "message" => %{"type" => "string", "encrypted" => true},
                "target" => %{"type" => "string"}
              },
              "required" => ["target", "message"],
              "additionalProperties" => false
            }
          }
        ]
      }
    ]

    assert {:ok, %{body: %{"id" => "resp_compatible_codex_schema"}}} =
             AIGateway.create_response(
               agent.uid,
               %{"model" => "primary", "input" => "Delegate.", "tools" => tools},
               request_context: %{"headers" => %{"originator" => "codex_cli_rs"}}
             )

    assert_receive {:gateway_request, codex_request}
    assert codex_request.body["tools"] == tools
    refute Map.has_key?(codex_request.body, "__ankole_native_encrypted_tool_fields")

    # The declaration survives for any caller on this wire, because the wire can
    # carry it. Who called is not the question; what the wire can express is.
    assert {:ok, %{body: %{"id" => "resp_compatible_codex_schema"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Delegate.",
               "tools" => tools
             })

    assert_receive {:gateway_request, main_agent_request}
    assert main_agent_request.body["tools"] == tools
  end

  test "a wire that cannot carry the encrypted marker strips it and emulates" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "chatcmpl_strip",
           "object" => "chat.completion",
           "choices" => [
             %{
               "index" => 0,
               "finish_reason" => "stop",
               "message" => %{"role" => "assistant", "content" => "done"}
             }
           ],
           "usage" => %{}
         }}
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "compatible-chat-completions-marker",
               provider_kind: "openai_compatible",
               base_url: "#{base_url}/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-compatible"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "compatible-chat-completions-marker",
               model: "gpt-compatible"
             })

    tools = [
      %{
        "type" => "function",
        "name" => "followup_task",
        "description" => "Send a follow-up task.",
        "parameters" => %{
          "type" => "object",
          "properties" => %{"message" => %{"type" => "string", "encrypted" => true}},
          "required" => ["message"],
          "additionalProperties" => false
        }
      }
    ]

    assert {:ok, _response} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Delegate.",
               "tools" => tools
             })

    assert_receive {:gateway_request, request}

    refute get_in(request.body, [
             "tools",
             Access.at(0),
             "function",
             "parameters",
             "properties",
             "message"
           ])["encrypted"]
  end

  test "ChatGPT Subscription keeps Codex tools native and runs Main Agent PTC locally" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        if request.body["stream"] == true do
          {:sse, 200,
           openai_response_stream_events(
             "resp_chatgpt_native_ptc_tools",
             request.body["model"],
             "Done."
           )}
        else
          {:json, 200,
           %{
             "id" => "resp_chatgpt_native_ptc_tools",
             "object" => "response",
             "status" => "completed",
             "output" => [],
             "usage" => %{}
           }}
        end
      end)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "chatgpt-native-ptc-tools",
               provider_kind: "chatgpt_subscription",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [
                   %{
                     "id" => "enterprise",
                     "label" => "Enterprise",
                     "access_token" => "access-token",
                     "account_id" => "account-id",
                     "auth_type" => "enterprise_access_token"
                   }
                 ]
               },
               connection_options: %{"transport" => %{}}
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "chatgpt-native-ptc-tools",
               model: "gpt-5.6-sol"
             })

    main_tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "description" => "Look up one record.",
        "allowed_callers" => ["direct", "programmatic"],
        "parameters" => %{"type" => "object", "properties" => %{}}
      },
      %{"type" => "programmatic_tool_calling"}
    ]

    assert {:ok, %{body: %{"id" => "resp_chatgpt_native_ptc_tools"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Run the main Agent program.",
               "tools" => main_tools
             })

    assert_receive {:gateway_request, main_request}
    assert Enum.map(main_request.body["tools"], & &1["name"]) == ["lookup", "program"]

    refute Enum.any?(
             main_request.body["tools"],
             &(&1["type"] == "programmatic_tool_calling")
           )

    codex_tools = [
      %{
        "type" => "mcp",
        "server_label" => "inventory",
        "server_url" => "https://mcp.example.test",
        "require_approval" => "never",
        "allowed_callers" => ["programmatic"]
      },
      %{"type" => "programmatic_tool_calling"}
    ]

    assert {:ok, %{body: %{"id" => "resp_chatgpt_native_ptc_tools"}}} =
             AIGateway.create_response(
               agent.uid,
               %{
                 "model" => "primary",
                 "input" => "Run the native program.",
                 "tools" => codex_tools
               },
               request_context: %{"headers" => %{"originator" => "codex_cli_rs"}}
             )

    assert_receive {:gateway_request, codex_request}
    assert codex_request.path == "responses"
    assert codex_request.body["tools"] == codex_tools
  end

  test "first-party OpenAI keeps function and custom PTC native" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_native_direct_tool",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_responses_provider!(agent.uid, base_url, "openai-native-direct-tool")

    tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "allowed_callers" => ["programmatic"],
        "parameters" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "type" => "custom",
        "name" => "apply",
        "allowed_callers" => ["programmatic"],
        "format" => %{"type" => "text"}
      },
      %{"type" => "programmatic_tool_calling"}
    ]

    assert {:ok, %{body: %{"id" => "resp_native_direct_tool"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Run tools.",
               "tools" => tools
             })

    assert_receive {:gateway_request, request}
    assert request.body["tools"] == tools
  end

  test "first-party OpenAI tool ownership stays native without a request-local PTC declaration" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_native_ptc_history",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_responses_provider!(agent.uid, base_url, "openai-native-ptc-history")

    caller = %{"type" => "program", "caller_id" => "prog_native"}

    history = [
      %{
        "type" => "program",
        "call_id" => "prog_native",
        "code" => "await tools.lookup({});",
        "fingerprint" => "opaque-native-token",
        "status" => "completed"
      },
      %{
        "type" => "function_call",
        "call_id" => "nested_native",
        "name" => "lookup",
        "arguments" => "{}",
        "status" => "completed",
        "caller" => caller
      },
      %{
        "type" => "function_call_output",
        "call_id" => "nested_native",
        "output" => "ok",
        "caller" => caller
      }
    ]

    tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "parameters" => %{"type" => "object", "properties" => %{}}
      }
    ]

    assert {:ok, %{body: %{"id" => "resp_native_ptc_history"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => history,
               "tools" => tools,
               "store" => false
             })

    assert_receive {:gateway_request, request}
    assert request.body["input"] == history
    assert request.body["tools"] == tools
    assert request.body["store"] == false
  end

  test "first-party OpenAI passes Tool Search and deferred contracts through unchanged" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 200,
         %{
           "id" => "resp_native_tool_search",
           "object" => "response",
           "status" => "completed",
           "output" => [],
           "usage" => %{}
         }}
      end)

    configure_openai_responses_provider!(agent.uid, base_url, "openai-native-tool-search")

    tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "description" => "Look up a record.",
        "parameters" => %{"type" => "object", "properties" => %{}},
        "defer_loading" => true,
        "allowed_callers" => ["direct", "programmatic"]
      },
      %{"type" => "tool_search", "execution" => "server"},
      %{"type" => "programmatic_tool_calling"}
    ]

    assert {:ok, %{body: %{"id" => "resp_native_tool_search"}}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Find and use the lookup tool.",
               "tools" => tools
             })

    assert_receive {:gateway_request, request}
    assert request.body["tools"] == tools
  end

  test "local_shell does not invent an allowed_callers contract" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 500, %{"error" => %{"message" => "must not dispatch"}}}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-invalid-local-shell-ptc"
    )

    assert {:error,
            %OpenAIError{
              status: 400,
              type: "invalid_request_error",
              code: "unsupported_tool_type"
            }} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Run tools.",
               "tools" => [
                 %{"type" => "local_shell", "allowed_callers" => ["programmatic"]},
                 %{"type" => "programmatic_tool_calling"}
               ]
             })

    refute_receive {:gateway_request, _request}
  end

  test "positive max_tool_calls accepts mixed local and provider effect owners" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 500, %{"error" => %{"message" => "not called during preparation"}}}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-mixed-tool-budget"
    )

    local_tools = [
      %{
        "type" => "function",
        "name" => "lookup",
        "allowed_callers" => ["programmatic"],
        "parameters" => %{"type" => "object", "properties" => %{}}
      },
      %{"type" => "programmatic_tool_calling"}
    ]

    request = %{
      "model" => "primary",
      "input" => "Run tools.",
      "tools" => local_tools ++ [%{"type" => "web_search"}],
      "max_tool_calls" => 1
    }

    assert {:ok, %{driver: :response_stream, request: ^request}} =
             ResponsesPreparation.prepare(agent.uid, request)

    refute_receive {:gateway_request, _request}
  end

  test "positive max_tool_calls accepts a single local effect owner" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:json, 500, %{"error" => %{"message" => "not called during preparation"}}}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-local-tool-budget"
    )

    cases = [
      [
        %{
          "type" => "function",
          "name" => "lookup",
          "allowed_callers" => ["programmatic"],
          "parameters" => %{"type" => "object", "properties" => %{}}
        },
        %{"type" => "programmatic_tool_calling"}
      ],
      [
        %{
          "type" => "function",
          "name" => "lookup",
          "defer_loading" => true,
          "parameters" => %{"type" => "object", "properties" => %{}}
        },
        %{"type" => "tool_search", "execution" => "server"}
      ]
    ]

    for tools <- cases do
      assert {:ok, %{driver: :response_stream}} =
               ResponsesPreparation.prepare(agent.uid, %{
                 "model" => "primary",
                 "input" => "Run tools.",
                 "tools" => tools,
                 "max_tool_calls" => 1
               })
    end

    projection_only = [
      %{
        "type" => "namespace",
        "name" => "crm",
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup",
            "parameters" => %{"type" => "object", "properties" => %{}}
          }
        ]
      },
      %{"type" => "web_search"}
    ]

    assert {:ok, %{driver: :single_request}} =
             ResponsesPreparation.prepare(agent.uid, %{
               "model" => "primary",
               "input" => "Run tools.",
               "tools" => projection_only,
               "max_tool_calls" => 1
             })

    refute_receive {:gateway_request, _request}
  end

  test "non-streaming server Tool Search drives internal streamed rounds and returns one final body" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        if provider_input_has_output?(request.body["input"], "call_search_market") do
          {:sse, 200,
           openai_response_stream_events(
             "resp_search_final",
             request.body["model"],
             "Market data is ready."
           )}
        else
          {:sse, 200,
           openai_function_call_stream_events(
             "resp_search_first",
             request.body["model"],
             "tool_search",
             %{"paths" => ["market_quote"]},
             "call_search_market"
           )}
        end
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-non-stream-tool-search"
    )

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Find and use the market quote tool.",
               "tools" => [
                 %{
                   "type" => "function",
                   "name" => "market_quote",
                   "description" => "Returns a current market quote.",
                   "defer_loading" => true,
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{
                       "symbol" => %{"type" => "string"}
                     }
                   }
                 }
               ]
             })

    requests = collect_gateway_requests(2, []) |> Enum.reverse()
    assert Enum.all?(requests, &(&1.body["stream"] == true))

    assert Enum.map(body["output"], & &1["type"]) == [
             "tool_search_call",
             "tool_search_output",
             "message"
           ]

    assert get_in(body, ["output", Access.at(1), "tools", Access.at(0)]) == %{
             "type" => "namespace",
             "name" => "functions",
             "description" => "",
             "tools" => [
               %{
                 "type" => "function",
                 "name" => "market_quote",
                 "description" => "Returns a current market quote.",
                 "allowed_callers" => ["direct"],
                 "defer_loading" => true,
                 "parameters" => %{
                   "type" => "object",
                   "properties" => %{"symbol" => %{"type" => "string"}}
                 }
               }
             ]
           }
  end

  test "non-streaming mixed tool owners do not execute a gateway effect beyond the shared limit" do
    %{principal: agent} = agent_fixture()

    arguments = Ankole.JSON.encode!(%{"paths" => ["market_quote"]})

    search_call = %{
      "type" => "function_call",
      "id" => "fc_search_over_budget",
      "name" => "tool_search",
      "call_id" => "call_search_over_budget",
      "status" => "completed",
      "arguments" => arguments
    }

    web_search = %{
      "type" => "web_search_call",
      "id" => "web_budget_winner",
      "status" => "completed",
      "action" => %{"type" => "search"}
    }

    response = %{
      "id" => "resp_mixed_tool_budget",
      "object" => "response",
      "status" => "in_progress",
      "model" => "gpt-compatible",
      "output" => []
    }

    base_url =
      start_recording_upstream(self(), fn _request ->
        {:sse, 200,
         [
           %{"type" => "response.created", "sequence_number" => 0, "response" => response},
           %{
             "type" => "response.output_item.done",
             "sequence_number" => 1,
             "output_index" => 0,
             "item" => search_call
           },
           %{
             "type" => "response.output_item.done",
             "sequence_number" => 2,
             "output_index" => 1,
             "item" => web_search
           },
           %{
             "type" => "response.completed",
             "sequence_number" => 3,
             "response" => %{
               response
               | "status" => "completed",
                 "output" => [search_call, web_search]
             }
           }
         ]}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-non-stream-mixed-tool-budget"
    )

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => "Search once.",
               "max_tool_calls" => 1,
               "tools" => [
                 %{
                   "type" => "function",
                   "name" => "market_quote",
                   "defer_loading" => true,
                   "parameters" => %{"type" => "object", "properties" => %{}}
                 },
                 %{"type" => "web_search"}
               ]
             })

    assert_receive {:gateway_request, request}
    assert request.body["max_tool_calls"] == 1
    refute_receive {:gateway_request, _request}

    assert body["status"] == "completed"
    assert Enum.map(body["output"], & &1["type"]) == ["web_search_call"]
  end

  test "non-streaming PTC waits for the async program after native done and returns one final body" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    base_url =
      start_recording_upstream(test_pid, fn request ->
        if provider_input_has_output?(request.body["input"], "call_program_http") do
          {:sse, 200,
           openai_response_stream_events(
             "resp_program_final",
             request.body["model"],
             "The program returned 42."
           )}
        else
          {:sse, 200,
           openai_function_call_stream_events(
             "resp_program_first",
             request.body["model"],
             "program",
             %{"code" => "text('42')"},
             "call_program_http"
           )}
        end
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-non-stream-ptc"
    )

    runner = fn code, bindings, memo ->
      send(test_pid, {:http_program_runner_started, self(), code, bindings, memo})

      receive do
        :release_http_program ->
          {:ok,
           %{
             status: :completed,
             output: [%{kind: "text", value: "42"}],
             pending_calls: []
           }}
      end
    end

    response_task =
      Task.async(
        Repo.bind_tenant(fn ->
          AIGateway.create_response(
            agent.uid,
            %{
              "model" => "primary",
              "input" => "Run a program.",
              "tools" => programmatic_tools()
            },
            program_runner: runner
          )
        end)
      )

    assert_receive {:http_program_runner_started, program_pid, "text('42')",
                    [%{"namespace" => nil, "name" => "market", "global_name" => "market"}], []},
                   2_000

    # The upstream SSE response has already closed. Its native :done must not
    # terminate the public response while the admitted program task is live.
    refute Task.yield(response_task, 50)
    refute_receive {:http_program_runner_started, _pid, _code, _bindings, _memo}

    send(program_pid, :release_http_program)

    assert {:ok, %{body: body}} = Task.await(response_task, 5_000)

    requests = collect_gateway_requests(2, []) |> Enum.reverse()
    assert Enum.all?(requests, &(&1.body["stream"] == true))

    assert Enum.map(body["output"], & &1["type"]) == [
             "program",
             "program_output",
             "message"
           ]

    assert get_in(body, ["output", Access.at(1), "result"]) == "42"
  end

  test "custom tools are emulated as function tools for a connection without official OpenAI tool support" do
    %{principal: agent} = agent_fixture()
    input_source = "console.log(1)"

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200,
         %{
           "id" => "resp_emulated_custom",
           "object" => "response",
           "status" => "completed",
           "model" => request.body["model"],
           "usage" => %{},
           "output" => [
             %{
               "type" => "function_call",
               "id" => "fc_call_exec_next",
               "call_id" => "call_exec_next",
               "name" => "exec",
               "status" => "completed",
               "arguments" => Ankole.JSON.encode!(%{"input" => "pwd"})
             }
           ]
         }}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-emulated-custom"
    )

    assert {:ok, %{body: body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 text_message("user", "Run the code."),
                 %{
                   "type" => "custom_tool_call",
                   "call_id" => "call_exec_prev",
                   "name" => "exec",
                   "input" => input_source
                 },
                 %{
                   "type" => "custom_tool_call_output",
                   "call_id" => "call_exec_prev",
                   "output" => "1"
                 }
               ],
               "tools" => [
                 %{
                   "type" => "custom",
                   "name" => "exec",
                   "description" => "Run source code.",
                   "format" => %{
                     "type" => "grammar",
                     "syntax" => "lark",
                     "definition" => "start: SOURCE"
                   }
                 }
               ]
             })

    assert_receive {:gateway_request, request}
    refute Map.has_key?(request.body, "__ankole_emulate_custom_tools")

    assert [tool] = request.body["tools"]
    assert tool["type"] == "function"
    assert tool["name"] == "exec"
    assert tool["parameters"]["required"] == ["input"]

    call_types = Enum.map(request.body["input"], & &1["type"])
    assert "function_call" in call_types
    assert "function_call_output" in call_types
    refute "custom_tool_call" in call_types
    refute "custom_tool_call_output" in call_types

    lowered_call = Enum.find(request.body["input"], &(&1["type"] == "function_call"))
    assert lowered_call["arguments"] == Ankole.JSON.encode!(%{"input" => input_source})

    assert [restored_call] = body["output"]
    assert restored_call["type"] == "custom_tool_call"
    assert restored_call["call_id"] == "call_exec_next"
    assert restored_call["input"] == "pwd"
    refute Map.has_key?(restored_call, "arguments")
  end

  test "custom tools pass through for a connection that declares official OpenAI tool support" do
    %{principal: agent} = agent_fixture()

    base_url =
      start_recording_upstream(self(), fn request ->
        {:json, 200,
         %{
           "id" => "resp_official_custom",
           "object" => "response",
           "status" => "completed",
           "model" => request.body["model"],
           "usage" => %{},
           "output" => [
             %{
               "type" => "message",
               "id" => "msg_official",
               "role" => "assistant",
               "status" => "completed",
               "content" => [%{"type" => "output_text", "text" => "Done.", "annotations" => []}]
             }
           ]
         }}
      end)

    configure_openai_compatible_responses_provider!(
      agent.uid,
      base_url,
      "compatible-official-custom",
      %{"supports_openai_tools" => true}
    )

    assert {:ok, %{body: _body}} =
             AIGateway.create_response(agent.uid, %{
               "model" => "primary",
               "input" => [
                 %{
                   "type" => "custom_tool_call",
                   "call_id" => "call_exec_prev",
                   "name" => "exec",
                   "input" => "console.log(1)"
                 },
                 %{
                   "type" => "custom_tool_call_output",
                   "call_id" => "call_exec_prev",
                   "output" => "1"
                 }
               ],
               "tools" => [
                 %{
                   "type" => "custom",
                   "name" => "exec",
                   "description" => "Run source code.",
                   "format" => %{
                     "type" => "grammar",
                     "syntax" => "lark",
                     "definition" => "start: SOURCE"
                   }
                 }
               ]
             })

    assert_receive {:gateway_request, request}
    refute Map.has_key?(request.body, "__ankole_emulate_custom_tools")
    assert [%{"type" => "custom"}] = request.body["tools"]

    assert Enum.map(request.body["input"], & &1["type"]) == [
             "custom_tool_call",
             "custom_tool_call_output"
           ]
  end

  defp openai_function_call_stream_events(response_id, model, name, arguments, call_id) do
    encoded_arguments = Ankole.JSON.encode!(arguments)

    response = %{
      "id" => response_id,
      "object" => "response",
      "status" => "in_progress",
      "model" => model,
      "output" => []
    }

    call = %{
      "type" => "function_call",
      "id" => "fc_#{call_id}",
      "name" => name,
      "call_id" => call_id,
      "status" => "completed",
      "arguments" => encoded_arguments
    }

    [
      %{"type" => "response.created", "sequence_number" => 0, "response" => response},
      %{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => %{call | "status" => "in_progress", "arguments" => ""}
      },
      %{
        "type" => "response.function_call_arguments.delta",
        "sequence_number" => 2,
        "item_id" => call["id"],
        "output_index" => 0,
        "delta" => encoded_arguments
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => 3,
        "output_index" => 0,
        "item" => call
      },
      %{
        "type" => "response.completed",
        "sequence_number" => 4,
        "response" => %{response | "status" => "completed", "output" => [call]}
      }
    ]
  end

  defp provider_input_has_output?(input, call_id) when is_list(input) do
    Enum.any?(input, fn
      %{"type" => "function_call_output", "call_id" => ^call_id} -> true
      _item -> false
    end)
  end

  defp provider_input_has_output?(_input, _call_id), do: false
end
