defmodule Ankole.AIGateway.StatefulLifecycleTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.AIGatewayCase

  import Ankole.AIGateway.ResponseFixtures

  alias Ankole.AIGateway.CredentialPool

  alias Ankole.AIGateway.StatefulLifecycle
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Signals.Signal
  alias Ankole.Repo

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "retrieved Responses preserve nested token usage details" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "nested-usage-projection")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "nested-usage", [
        text_message("user", "hello")
      ])

    usage = %{
      "input_tokens" => 20,
      "output_tokens" => 7,
      "total_tokens" => 27,
      "input_tokens_details" => %{"cached_tokens" => 11},
      "output_tokens_details" => %{"reasoning_tokens" => 4}
    }

    message
    |> Ecto.Changeset.change(metadata: Map.put(message.metadata, "usage", usage))
    |> Repo.update!()

    assert {:ok, %{body: body}} =
             StatefulLifecycle.retrieve_response(agent.uid, "resp_#{message.id}")

    assert body["usage"] == usage
  end

  test "OpenRouter stateful requests use the durable conversation id as session_id" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openrouter-stateful-session",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openrouter"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-stateful-session",
               model: "openai/gpt-5.6-sol"
             })

    assert {:ok, conversation} =
             Ankole.AIGatewayCase.ensure_conversation(agent.uid, "openrouter-stateful-session")

    assert {:ok, previous} =
             start_stateful_message(agent.uid, conversation, "openrouter-stateful-anchor", [
               text_message("user", "first user message")
             ])

    assert {:ok, previous} = ResponseCommit.commit_complete(previous, [])

    assert {:ok, request, stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "continue")],
               "store" => true,
               "previous_response_id" => "resp_#{previous.id}",
               "prompt_cache_key" => "shared-prefix"
             })

    assert request.response_context.provider_options["session_id"] == conversation.id
    assert request.response_context.provider_options["prompt_cache_key"] == "shared-prefix"
    refute conversation.id == "shared-prefix"
    assert stateful_context.message.conversation_id == conversation.id
  end

  test "websocket responses require store true before continuation fields" do
    %{principal: agent} = agent_fixture()
    previous_response_id = "resp_#{Ecto.UUID.generate()}"
    conversation_id = "conv_#{Ecto.UUID.generate()}"

    assert {:error, :stateful_anchor_conflict} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "store" => true,
               "conversation" => conversation_id,
               "previous_response_id" => previous_response_id
             })

    for request <- [
          %{
            "model" => "primary",
            "input" => "hello",
            "previous_response_id" => previous_response_id
          },
          %{"model" => "primary", "input" => "hello", "conversation" => conversation_id},
          %{
            "model" => "primary",
            "input" => "hello",
            "store" => false,
            "conversation" => conversation_id
          }
        ] do
      assert {:error, :stateful_store_required} =
               AIGateway.open_websocket_stream(agent.uid, request)
    end

    refute_receive {:gateway_request, _request}
  end

  test "websocket store true without previous_response_id or conversation creates a managed conversation" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-auto-conversation",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-auto-conversation",
               model: "gpt-5.5"
             })

    assert {:ok, request, stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "store" => true,
               "metadata" => %{
                 "request_tag" => "kept",
                 "extra" => %{"visibility" => "public"}
               }
             })

    provider_request = request.response_context.request

    assert provider_request["store"] == false

    assert provider_request["metadata"] == %{
             "request_tag" => "kept",
             "extra" => %{"visibility" => "public"}
           }

    refute Map.has_key?(provider_request, "conversation")
    refute Map.has_key?(provider_request, "previous_response_id")

    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "hello"}]
             }
           ] = provider_request["input"]

    conversation =
      Repo.one!(
        from(conversation in Conversation,
          where: conversation.subject_uid == ^agent.uid,
          where:
            fragment("?->>'managed_by_stateful_responses_api'", conversation.metadata) == "true"
        )
      )

    assert String.starts_with?(conversation.conversation_key, "stateful-responses-api:")

    assert conversation.metadata == %{
             "managed_by_stateful_responses_api" => true,
             "request_tag" => "kept",
             "extra" => %{"visibility" => "public"}
           }

    assert stateful_context.message.conversation_id == conversation.id
    assert stateful_context.message.status == "generating"
  end

  test "websocket stateful requests reject wires that cannot replay Responses history" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "claude-stateful-gate",
               provider_kind: "claude",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-claude"}]
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "claude-stateful-gate",
               model: "claude-opus-4-6"
             })

    assert {:error, {:stateful_wire_unsupported, "claude", :anthropic_messages}} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "hello",
               "store" => true
             })

    # The same selector stays usable for stateless requests.
    assert {:ok, _request, nil} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "hello"
             })

    refute_receive {:gateway_request, _request}
  end

  test "websocket stateful previous_response_id expands history without provider state fields" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-previous-websocket",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-previous-websocket",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-previous-only")

    image_url = "data:image/png;base64,iVBORw0KGgo="

    request_items = [
      %{
        "id" => "msg_previous_user",
        "type" => "message",
        "role" => "user",
        "content" => [
          %{"type" => "input_text", "text" => "first user"},
          %{"type" => "input_image", "image_url" => image_url}
        ]
      }
    ]

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "dispatch-previous-a", request_items)

    terminal_items = [
      %{
        "id" => "msg_previous_assistant",
        "type" => "message",
        "status" => "completed",
        "role" => "assistant",
        "content" => [
          %{"type" => "output_text", "text" => "first assistant", "annotations" => []}
        ]
      }
    ]

    {:ok, first} = ResponseCommit.commit_complete(first, terminal_items)

    current_input = [
      %{
        "type" => "message",
        "role" => "user",
        "content" => [%{"type" => "input_text", "text" => "next user"}]
      }
    ]

    assert {:error, :invalid_anchor} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => first.id
             })

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{first.id}",
               "prompt_cache_key" => "cache-ws",
               "metadata" => %{
                 "signal_id" => "internal-event-id",
                 "kept" => "public"
               }
             })

    provider_request = request.response_context.request

    assert request.upstream.kind == :websocket_text
    history_input = Enum.map(request_items, &Map.delete(&1, "id")) ++ terminal_items
    assert provider_request["input"] == history_input ++ current_input

    assert get_in(provider_request, ["input", Access.at(0), "content", Access.at(1)]) == %{
             "type" => "input_image",
             "image_url" => image_url
           }

    refute Map.has_key?(Enum.at(provider_request["input"], 0), "id")
    assert Enum.at(provider_request["input"], 1)["id"] == "msg_previous_assistant"

    refute Map.has_key?(provider_request, "service_tier")
    assert provider_request["prompt_cache_key"] == "cache-ws"
    refute Map.has_key?(provider_request, "previous_response_id")
    assert provider_request["store"] == false
    refute Map.has_key?(provider_request, "conversation")

    assert provider_request["metadata"] == %{
             "signal_id" => "internal-event-id",
             "kept" => "public"
           }

    assert {:ok, no_event_request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{first.id}"
             })

    assert no_event_request.response_context.request["input"] == history_input ++ current_input
    refute Map.has_key?(no_event_request.response_context.request, "metadata")

    assert {:ok, string_request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => "next user as a string",
               "store" => true,
               "previous_response_id" => "resp_#{first.id}",
               "metadata" => %{"signal_id" => "internal-event-id-string"}
             })

    assert string_request.response_context.request["input"] ==
             history_input ++
               [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "next user as a string"}]
                 }
               ]
  end

  test "websocket stateful replay keeps only ids required by Responses input items" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-replay-ids",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-replay-ids",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-stateful-replay-ids")

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "dispatch-stateful-replay-ids-a", [
        text_message("user", "Run the tools.")
      ])

    history_items = [
      %{
        "id" => "assistant_message_item_id",
        "type" => "message",
        "role" => "assistant",
        "status" => "completed",
        "content" => [
          %{"type" => "output_text", "text" => "Tools finished.", "annotations" => []}
        ]
      },
      %{
        "id" => "referenced_item_id",
        "type" => "item_reference"
      },
      %{"id" => "implicit_referenced_item_id"},
      %{"id" => "null_referenced_item_id", "type" => nil},
      %{
        "id" => "program_item_id",
        "type" => "program",
        "call_id" => "program_call_id",
        "code" => "text('done');",
        "fingerprint" => "program_fingerprint"
      },
      %{
        "id" => "program_output_item_id",
        "type" => "program_output",
        "call_id" => "program_call_id",
        "status" => "completed",
        "result" => "done"
      },
      %{
        "id" => "mcp_call_item_id",
        "type" => "mcp_call",
        "arguments" => "{}",
        "name" => "lookup",
        "server_label" => "inventory",
        "status" => "completed",
        "output" => "found"
      },
      %{
        "id" => "mcp_list_tools_item_id",
        "type" => "mcp_list_tools",
        "server_label" => "inventory",
        "tools" => []
      },
      %{
        "id" => "mcp_approval_request_item_id",
        "type" => "mcp_approval_request",
        "arguments" => "{}",
        "name" => "update",
        "server_label" => "inventory"
      },
      %{
        "id" => "optional_mcp_approval_response_id",
        "type" => "mcp_approval_response",
        "approval_request_id" => "mcp_approval_request_item_id",
        "approve" => true
      },
      %{
        "id" => "code_interpreter_item_id",
        "type" => "code_interpreter_call",
        "code" => "1 + 1",
        "container_id" => "container_1",
        "outputs" => [],
        "status" => "completed"
      },
      %{
        "id" => "local_shell_item_id",
        "type" => "local_shell_call",
        "call_id" => "local_shell_call_id",
        "action" => %{"type" => "exec", "command" => ["true"], "env" => %{}},
        "status" => "completed"
      },
      %{
        "id" => "local_shell_call_id",
        "type" => "local_shell_call_output",
        "output" => "{}"
      },
      %{
        "id" => "computer_call_item_id",
        "type" => "computer_call",
        "call_id" => "computer_call_id",
        "pending_safety_checks" => [],
        "status" => "completed"
      },
      %{
        "id" => "optional_computer_output_id",
        "type" => "computer_call_output",
        "call_id" => "computer_call_id",
        "output" => %{
          "type" => "computer_screenshot",
          "image_url" => "data:image/png;base64,eA=="
        }
      },
      %{
        "id" => "file_search_item_id",
        "type" => "file_search_call",
        "queries" => ["inventory"],
        "status" => "completed"
      },
      %{
        "id" => "reasoning_item_id",
        "type" => "reasoning",
        "summary" => [],
        "encrypted_content" => "encrypted"
      },
      %{
        "id" => "web_search_item_id",
        "type" => "web_search_call",
        "action" => %{"type" => "search", "queries" => ["inventory"]},
        "status" => "completed"
      },
      %{
        "id" => "image_generation_item_id",
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => "image"
      },
      %{
        "id" => "optional_function_call_id",
        "type" => "function_call",
        "call_id" => "function_call_id",
        "name" => "lookup",
        "arguments" => "{}"
      },
      %{
        "id" => "optional_function_output_id",
        "type" => "function_call_output",
        "call_id" => "function_call_id",
        "output" => "found"
      },
      %{
        "id" => "optional_custom_call_id",
        "type" => "custom_tool_call",
        "call_id" => "custom_call_id",
        "name" => "render",
        "input" => "report"
      },
      %{
        "id" => "optional_custom_output_id",
        "type" => "custom_tool_call_output",
        "call_id" => "custom_call_id",
        "output" => "rendered"
      },
      %{
        "id" => "optional_shell_call_id",
        "type" => "shell_call",
        "call_id" => "shell_call_id",
        "action" => %{"commands" => ["true"]},
        "status" => "completed"
      },
      %{
        "id" => "optional_shell_output_id",
        "type" => "shell_call_output",
        "call_id" => "shell_call_id",
        "output" => []
      },
      %{
        "id" => "optional_apply_patch_call_id",
        "type" => "apply_patch_call",
        "call_id" => "apply_patch_call_id",
        "operation" => %{"type" => "delete_file", "path" => "old.txt"},
        "status" => "completed"
      },
      %{
        "id" => "optional_apply_patch_output_id",
        "type" => "apply_patch_call_output",
        "call_id" => "apply_patch_call_id",
        "status" => "completed"
      },
      %{
        "id" => "optional_tool_search_call_id",
        "type" => "tool_search_call",
        "execution" => "client",
        "call_id" => "tool_search_call_id",
        "arguments" => %{"query" => "inventory"},
        "status" => "completed"
      },
      %{
        "id" => "optional_tool_search_output_id",
        "type" => "tool_search_output",
        "execution" => "client",
        "call_id" => "tool_search_call_id",
        "tools" => [],
        "status" => "completed"
      }
    ]

    {:ok, first} = ResponseCommit.commit_complete(first, history_items)

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "Continue.")],
               "store" => true,
               "previous_response_id" => "resp_#{first.id}",
               "tools" => [
                 %{
                   "type" => "mcp",
                   "server_label" => "inventory",
                   "server_url" => "https://mcp.example.test",
                   "allowed_callers" => ["programmatic"]
                 },
                 %{"type" => "programmatic_tool_calling"}
               ]
             })

    provider_input = request.response_context.request["input"]

    required_ids = %{
      "code_interpreter_call" => "code_interpreter_item_id",
      "computer_call" => "computer_call_item_id",
      "file_search_call" => "file_search_item_id",
      "image_generation_call" => "image_generation_item_id",
      "item_reference" => "referenced_item_id",
      "local_shell_call" => "local_shell_item_id",
      "local_shell_call_output" => "local_shell_call_id",
      "mcp_approval_request" => "mcp_approval_request_item_id",
      "mcp_call" => "mcp_call_item_id",
      "mcp_list_tools" => "mcp_list_tools_item_id",
      "program" => "program_item_id",
      "program_output" => "program_output_item_id",
      "reasoning" => "reasoning_item_id",
      "web_search_call" => "web_search_item_id"
    }

    Enum.each(required_ids, fn {type, id} ->
      assert %{"id" => ^id} = Enum.find(provider_input, &(&1["type"] == type))
    end)

    assert %{"id" => "assistant_message_item_id"} =
             Enum.find(
               provider_input,
               &(&1["type"] == "message" and &1["role"] == "assistant")
             )

    Enum.each(~w(implicit_referenced_item_id null_referenced_item_id), fn id ->
      assert %{"id" => ^id, "type" => "item_reference"} =
               Enum.find(provider_input, &(&1["id"] == id))
    end)

    optional_id_types = ~w(
      apply_patch_call
      apply_patch_call_output
      computer_call_output
      custom_tool_call
      custom_tool_call_output
      function_call
      function_call_output
      mcp_approval_response
      shell_call
      shell_call_output
      tool_search_call
      tool_search_output
    )

    Enum.each(optional_id_types, fn type ->
      item = Enum.find(provider_input, &(&1["type"] == type))
      assert is_map(item)
      refute Map.has_key?(item, "id")
    end)
  end

  test "stateful replay rejection writes one neutral checkpoint and recovers the next turn" do
    %{principal: agent} = agent_fixture()
    with_compaction_config(threshold: 0.50, max_threshold_tokens: 100_000, tail_rows: 2)

    {:ok, provider_state} =
      Agent.start_link(fn -> %{light_requests: [], primary_requests: []} end)

    base_url =
      start_recording_upstream(self(), fn request ->
        case request.body["model"] do
          "gpt-compact-light" ->
            Agent.update(provider_state, fn state ->
              %{state | light_requests: state.light_requests ++ [request]}
            end)

            {:sse, 200,
             openai_response_stream_events(
               "resp_replay_recovery_summary",
               "gpt-compact-light",
               "## Active Task\nThe earlier conversation was recovered locally."
             )}

          "gpt-main" ->
            attempt =
              Agent.get_and_update(provider_state, fn state ->
                requests = state.primary_requests ++ [request]
                {length(requests), %{state | primary_requests: requests}}
              end)

            if attempt <= 2 do
              {:json, 400,
               %{
                 "error" => %{
                   "message" => "arbitrary provider detail",
                   "param" => "input",
                   "type" => "invalid_request_error"
                 }
               }}
            else
              {:sse, 200,
               openai_response_stream_events(
                 "resp_replay_recovery_next",
                 "gpt-main",
                 "Recovered on the next turn."
               )}
            end
        end
      end)

    create_openai_compaction_provider!(
      agent,
      "openai-stateful-replay-recovery",
      base_url
    )

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-stateful-replay-recovery")

    {:ok, m1} =
      start_stateful_message(agent.uid, conversation, "replay-recovery-a", [
        text_message("user", "first user request")
      ])

    {:ok, m1} =
      ResponseCommit.commit_complete(m1, [
        text_message("assistant", "first assistant response")
      ])

    {:ok, m2} =
      start_linked_stateful_message(agent.uid, conversation, m1, "replay-recovery-b", [
        text_message("user", "second user request")
      ])

    {:ok, m2} =
      ResponseCommit.commit_complete(m2, [
        %{
          "id" => "rs_poisoned_replay",
          "type" => "reasoning",
          "summary" => [
            %{
              "type" => "summary_text",
              "text" => "visible provider reasoning summary"
            }
          ],
          "encrypted_content" => "POISONED_REASONING_CIPHERTEXT"
        },
        %{
          "id" => "msg_poisoned_replay",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "second assistant response",
              "annotations" => []
            }
          ]
        }
      ])

    {:ok, m3} =
      start_linked_stateful_message(agent.uid, conversation, m2, "replay-recovery-tail", [
        text_message("user", "tail user request")
      ])

    {:ok, m3} =
      ResponseCommit.commit_complete(m3, [
        %{
          "id" => "mcp_poisoned_replay",
          "type" => "mcp_call",
          "call_id" => "mcp_call_poisoned_replay",
          "name" => "lookup",
          "server_label" => "inventory",
          "status" => "completed",
          "output" => "tail provider result",
          "encrypted_function_args" => "POISONED_FUNCTION_CIPHERTEXT"
        },
        %{
          "id" => "msg_tail_poisoned_replay",
          "type" => "message",
          "role" => "assistant",
          "status" => "completed",
          "content" => [
            %{
              "type" => "output_text",
              "text" => "tail assistant response",
              "annotations" => []
            }
          ]
        }
      ])

    conversation = seed_checkpoint_memory!(agent, conversation, "memory-recovery-seed")

    failed_event =
      signal_fixture(agent.uid, conversation.conversation_key, "replay-recovery-failed")

    failed_input = [text_message("user", "Wire Format: current request that retries once")]

    assert {:error, _reason} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => failed_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => failed_event.id}
             })

    %{light_requests: [summary_request], primary_requests: [first_request, retry_request]} =
      Agent.get(provider_state, & &1)

    first_request_json = Ankole.JSON.encode!(first_request.body)
    assert first_request_json =~ "rs_poisoned_replay"
    assert first_request_json =~ "msg_poisoned_replay"
    refute first_request_json =~ "__ankole_stateful_provider_replay"

    summary_request_json = Ankole.JSON.encode!(summary_request.body)
    refute summary_request_json =~ "MEMORY_ORION"
    refute summary_request_json =~ "POISONED_REASONING_CIPHERTEXT"
    refute summary_request_json =~ "POISONED_FUNCTION_CIPHERTEXT"

    retry_request_json = Ankole.JSON.encode!(retry_request.body)
    refute retry_request_json =~ "rs_poisoned_replay"
    refute retry_request_json =~ "msg_poisoned_replay"
    refute retry_request_json =~ "mcp_poisoned_replay"
    refute retry_request_json =~ "POISONED_REASONING_CIPHERTEXT"
    refute retry_request_json =~ "POISONED_FUNCTION_CIPHERTEXT"
    assert Enum.count(retry_request.body["input"], &(&1 == hd(failed_input))) == 1

    failed_run =
      Repo.get_by!(Message,
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        status: "error"
      )

    checkpoint = Repo.get!(Message, failed_run.previous_message_id)
    assert checkpoint.type == "checkpoint"
    assert checkpoint.status == "complete"
    assert checkpoint.previous_message_id == m3.id

    artifact = Repo.get!(CompactionArtifact, checkpoint.id)
    assert artifact.content["version"] == 2
    assert [_pack] = artifact.content["brain_context_pack"]
    refute Ankole.JSON.encode!(artifact.content["output"]) =~ "MEMORY_ORION"
    assert Ankole.JSON.encode!(hd(retry_request.body["input"])) =~ "MEMORY_ORION"

    artifact_json = Ankole.JSON.encode!(artifact.content["output"])
    refute artifact_json =~ "rs_poisoned_replay"
    refute artifact_json =~ "msg_poisoned_replay"
    refute artifact_json =~ "mcp_poisoned_replay"
    refute artifact_json =~ "POISONED_REASONING_CIPHERTEXT"
    refute artifact_json =~ "POISONED_FUNCTION_CIPHERTEXT"
    assert artifact_json =~ "visible provider reasoning summary"
    assert artifact_json =~ "second assistant response"
    assert artifact_json =~ "tail assistant response"

    next_event =
      signal_fixture(agent.uid, conversation.conversation_key, "replay-recovery-next")

    next_input = [text_message("user", "continue from the repaired checkpoint")]

    assert {:ok, stream, _meta} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => next_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => next_event.id}
             })

    assert {:ok, events} = collect_sse_chunks(stream, [])
    assert terminal_response_body!(events)["status"] == "completed"

    %{light_requests: [_summary_request], primary_requests: primary_requests} =
      Agent.get(provider_state, & &1)

    assert length(primary_requests) == 3
    next_request = List.last(primary_requests)
    next_request_json = Ankole.JSON.encode!(next_request.body)
    refute next_request_json =~ "rs_poisoned_replay"
    refute next_request_json =~ "msg_poisoned_replay"
    refute next_request_json =~ "POISONED_REASONING_CIPHERTEXT"

    assert Enum.any?(next_request.body["input"], fn item ->
             local_checkpoint_summary(item) ==
               "## Active Task\nThe earlier conversation was recovered locally."
           end)
  end

  test "stateful replay rejection after a provider event does not rebuild history" do
    %{principal: agent} = agent_fixture()
    {:ok, request_counts} = Agent.start_link(fn -> %{light: 0, primary: 0} end)

    base_url =
      start_recording_upstream(self(), fn request ->
        case request.body["model"] do
          "gpt-compact-light" ->
            Agent.update(request_counts, &Map.update!(&1, :light, fn count -> count + 1 end))

            {:sse, 200,
             openai_response_stream_events(
               "resp_late_rejection_summary",
               "gpt-compact-light",
               "## Active Task\nUnexpected summary."
             )}

          "gpt-main" ->
            Agent.update(request_counts, &Map.update!(&1, :primary, fn count -> count + 1 end))

            [created | _events] =
              openai_response_stream_events(
                "resp_late_rejection",
                "gpt-main",
                "partial response"
              )

            {:sse, 200, [created]}
        end
      end)

    create_openai_compaction_provider!(
      agent,
      "openai-stateful-late-replay-rejection",
      base_url
    )

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-stateful-late-rejection")

    {:ok, prior} =
      start_stateful_message(agent.uid, conversation, "late-rejection-prior", [
        text_message("user", "prior request")
      ])

    {:ok, prior} =
      ResponseCommit.commit_complete(prior, [
        %{
          "id" => "rs_late_rejection",
          "type" => "reasoning",
          "summary" => [],
          "encrypted_content" => "LATE_REJECTION_CIPHERTEXT"
        }
      ])

    event = signal_fixture(agent.uid, conversation.conversation_key, "late-rejection-run")

    assert {:ok, stream, _meta} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "current request")],
               "store" => true,
               "previous_response_id" => "resp_#{prior.id}",
               "metadata" => %{"signal_id" => event.id}
             })

    assert {:ok, events} = collect_sse_chunks(stream, [])
    assert terminal_response_body!(events)["status"] == "failed"
    assert Agent.get(request_counts, & &1) == %{light: 0, primary: 1}

    refute Repo.exists?(from(message in Message, where: message.type == "checkpoint"))
  end

  test "automatic stateful continuation closes client tool calls interrupted before durable output" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-interrupted-tool",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-interrupted-tool",
               model: "gpt-5.5"
             })

    cases = [
      {"function",
       %{
         "type" => "function_call",
         "call_id" => "call_interrupted_function",
         "name" => "command",
         "arguments" => Ankole.JSON.encode!(%{"command" => "sleep 40"})
       }, "function_call_output"},
      {"custom",
       %{
         "type" => "custom_tool_call",
         "call_id" => "call_interrupted_custom",
         "name" => "apply_patch",
         "input" => "*** Begin Patch\n*** Add File: report.md\n+pending\n*** End Patch\n"
       }, "custom_tool_call_output"}
    ]

    for {label, tool_call, expected_output_type} <- cases do
      {:ok, conversation} =
        Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-interrupted-tool-#{label}")

      original_input = [text_message("user", "run the interrupted #{label} tool")]

      {:ok, call_response} =
        start_stateful_message(
          agent.uid,
          conversation,
          "dispatch-interrupted-tool-call-#{label}",
          original_input
        )

      {:ok, call_response} = ResponseCommit.commit_complete(call_response, [tool_call])
      retry_input = [text_message("user", "run the interrupted #{label} tool")]

      assert {:ok, prepared, %{message: run}} =
               StatefulLifecycle.prepare_websocket_request(agent.uid, %{
                 "model" => "primary",
                 "input" => retry_input,
                 "store" => true,
                 "conversation" => "conv_#{conversation.id}",
                 "metadata" => %{"signal_id" => "interrupted-tool-retry-#{label}"}
               })

      [recovered_output | persisted_retry_input] = run.content

      assert recovered_output["type"] == expected_output_type
      assert recovered_output["call_id"] == tool_call["call_id"]
      assert recovered_output["output"] =~ "tool_execution_interrupted"
      assert persisted_retry_input == retry_input

      assert run.metadata["recovered_interrupted_tool_call_ids"] == [
               tool_call["call_id"]
             ]

      assert prepared.response_context.request["input"] ==
               Enum.map(call_response.content, &Map.delete(&1, "id")) ++
                 [recovered_output] ++ retry_input
    end

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-interrupted-nested-tool")

    nested_call = %{
      "type" => "function_call",
      "call_id" => "call_interrupted_nested",
      "name" => "lookup",
      "arguments" => "{}",
      "caller" => %{"type" => "program", "caller_id" => "program_interrupted"}
    }

    {:ok, call_response} =
      start_stateful_message(
        agent.uid,
        conversation,
        "dispatch-interrupted-nested-tool-call",
        [text_message("user", "run through a program")]
      )

    {:ok, call_response} = ResponseCommit.commit_complete(call_response, [nested_call])
    retry_input = [text_message("user", "continue")]

    assert {:ok, prepared, %{message: run}} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => retry_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "interrupted-nested-tool-retry"}
             })

    assert run.content == retry_input
    refute Map.has_key?(run.metadata, "recovered_interrupted_tool_call_ids")

    assert prepared.response_context.request["input"] ==
             [call_response.content |> hd() |> Map.delete("id")] ++ retry_input

    assert run.metadata["provider_projection_tool_result_quarantine"] == %{
             "non_executable_call_ids" => ["call_interrupted_nested"]
           }
  end

  test "provider projection drops legacy orphan outputs while preserving the raw row" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-orphan-projection",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-orphan-projection",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-orphan-projection")

    {:ok, anchor} =
      start_stateful_message(agent.uid, conversation, "dispatch-orphan-anchor", [
        text_message("user", "stable request")
      ])

    {:ok, anchor} =
      ResponseCommit.commit_complete(anchor, [text_message("assistant", "stable answer")])

    orphan_output = %{
      "type" => "function_call_output",
      "call_id" => "call_legacy_orphan",
      "output" => "legacy side effect result"
    }

    {:ok, legacy_orphan_row} =
      start_linked_stateful_message(
        agent.uid,
        conversation,
        anchor,
        "dispatch-orphan-row",
        [orphan_output]
      )

    {:ok, legacy_orphan_row} = ResponseCommit.commit_complete(legacy_orphan_row, [])
    current_input = [text_message("user", "continue safely")]

    assert {:ok, prepared, %{message: run}} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "orphan-projection-retry"}
             })

    projected_input = prepared.response_context.request["input"]

    refute Enum.any?(projected_input, fn item ->
             item["type"] == "function_call_output" and
               item["call_id"] == "call_legacy_orphan"
           end)

    assert run.metadata["provider_projection_tool_result_quarantine"] == %{
             "orphan_call_ids" => ["call_legacy_orphan"]
           }

    assert Repo.get!(Message, legacy_orphan_row.id).content == [orphan_output]
    assert run.content == current_input
  end

  test "provider projection drops structurally malformed calls and their outputs while preserving raw rows" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-malformed-call-projection",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-malformed-call-projection",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-malformed-call-projection")

    {:ok, legacy_row} =
      start_stateful_message(agent.uid, conversation, "dispatch-malformed-call-row", [
        text_message("user", "legacy request")
      ])

    malformed_call = %{
      "type" => "function_call",
      "status" => "incomplete",
      "call_id" => "call_legacy_partial",
      "name" => "patch",
      "arguments" => "{\"path\":\"/tmp/repor"
    }

    malformed_output = %{
      "type" => "function_call_output",
      "call_id" => "call_legacy_partial",
      "output" => "legacy output that must not be replayed"
    }

    partial_program = %{
      "type" => "program",
      "status" => "in_progress",
      "call_id" => "program_legacy_partial",
      "code" => "text('unfinished",
      "fingerprint" => "partial-program-fingerprint"
    }

    partial_program_output = %{
      "type" => "program_output",
      "call_id" => "program_legacy_partial",
      "status" => "completed",
      "result" => ~s({"status":"completed"})
    }

    {:ok, legacy_row} =
      ResponseCommit.commit_complete(legacy_row, [
        malformed_call,
        malformed_output,
        partial_program,
        partial_program_output
      ])

    assert {:ok, prepared, %{message: run}} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => [text_message("user", "continue safely")],
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => "malformed-call-projection-retry"}
             })

    projected_input = prepared.response_context.request["input"]

    refute Enum.any?(
             projected_input,
             &(&1["call_id"] in ["call_legacy_partial", "program_legacy_partial"])
           )

    assert run.metadata["provider_projection_tool_result_quarantine"] == %{
             "non_executable_call_ids" => [
               "call_legacy_partial",
               "program_legacy_partial"
             ]
           }

    assert Repo.get!(Message, legacy_row.id).content == [
             text_message("user", "legacy request"),
             malformed_call,
             malformed_output,
             partial_program,
             partial_program_output
           ]
  end

  test "websocket stateful instructions are request-scoped and are not inherited" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-instructions",
               provider_kind: "openai",
               base_url: "https://api.openai.test/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-instructions",
               model: "gpt-5.5"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-instructions-scope")

    signal =
      signal_fixture(agent.uid, conversation.conversation_key, "instructions-a")

    {:ok, first} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        request_items: [text_message("user", "first user")],
        metadata: %{
          "request_metadata" => %{"signal_id" => signal.id},
          "instructions" => "old instruction"
        }
      })

    {:ok, first} =
      ResponseCommit.commit_complete(first, [text_message("assistant", "first answer")])

    current_input = [text_message("user", "next user")]

    assert {:ok, request, _stateful_context} =
             StatefulLifecycle.prepare_websocket_request(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "previous_response_id" => "resp_#{first.id}",
               "metadata" => %{"signal_id" => "instructions-event"}
             })

    provider_request = request.response_context.request

    assert provider_request["input"] == first.content ++ current_input
    refute Map.has_key?(provider_request, "instructions")
  end

  test "websocket stateful max_tool_calls rejects invalid values" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-invalid-max-tool-calls")

    for invalid_value <- [-1, 1.5, "1"] do
      assert {:error, :invalid_max_tool_calls} =
               StatefulLifecycle.prepare_websocket_request(agent.uid, %{
                 "model" => "primary",
                 "input" => [text_message("user", "hello")],
                 "store" => true,
                 "conversation" => "conv_#{conversation.id}",
                 "max_tool_calls" => invalid_value,
                 "metadata" => %{"signal_id" => "invalid-max-tool-calls-event"}
               })
    end
  end

  test "websocket stateful conversation run stores latest visible leaf as durable anchor" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "openai-stateful-conversation-anchor",
               provider_kind: "openai",
               base_url: "http://127.0.0.1:1/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-openai"}]
               },
               connection_options: %{
                 "upstream_transport" => "websocket"
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openai-stateful-conversation-anchor",
               model: "gpt-main"
             })

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-conversation-anchor")

    {:ok, first} =
      start_stateful_message(agent.uid, conversation, "conversation-anchor-a", [
        text_message("user", "first user"),
        text_message("assistant", "first assistant")
      ])

    {:ok, first} = ResponseCommit.commit_complete(first, [])

    signal =
      signal_fixture(agent.uid, conversation.conversation_key, "conversation-anchor-b")

    current_input = [text_message("user", "second user")]

    assert {:error, _reason} =
             AIGateway.open_websocket_stream(agent.uid, %{
               "model" => "primary",
               "input" => current_input,
               "store" => true,
               "conversation" => "conv_#{conversation.id}",
               "metadata" => %{"signal_id" => signal.id}
             })

    [run] =
      Repo.all(Message)
      |> Enum.filter(&(get_in(&1.metadata, ["request_metadata", "signal_id"]) == signal.id))

    assert run.previous_message_id == first.id
    assert run.status == "error"
    assert run.content == current_input
    assert run.metadata["error"]["stage"] == "socket_open"
    assert is_nil(Repo.get!(Signal, signal.id).completed_at)
  end

  test "socket-open errors persist stable failure facts without provider text" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-safe-socket-error")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "safe-socket-error", [
        text_message("user", "hello")
      ])

    assert :ok =
             StatefulLifecycle.commit_socket_open_error(
               %{message_id: message.id},
               %Ankole.AIGateway.ProviderFailure{
                 kind: :invalid_response,
                 provider_status: 200,
                 provider_body: %{
                   "error" => %{
                     "code" => "invalid_shape",
                     "message" => "private provider body",
                     "type" => "provider_protocol_error"
                   }
                 }
               }
             )

    stored_error = Repo.get!(Message, message.id).metadata["error"]

    assert stored_error == %{
             "code" => "invalid_upstream_response",
             "failure_kind" => "invalid_response",
             "message" => "The upstream provider returned an invalid response.",
             "provider_error_code" => "invalid_shape",
             "provider_error_type" => "provider_protocol_error",
             "provider_status" => 200,
             "retryable" => true,
             "stage" => "socket_open"
           }

    encoded_error = Ankole.JSON.encode!(stored_error)
    refute encoded_error =~ "private provider body"

    for legacy_key <- ~w(body reason status provider_body_excerpt) do
      refute Map.has_key?(stored_error, legacy_key)
    end

    assert {:ok,
            %{
              body: %{
                "error" => %{
                  "code" => "invalid_upstream_response",
                  "message" => "The upstream provider returned an invalid response."
                }
              }
            }} = StatefulLifecycle.retrieve_response(agent.uid, "resp_#{message.id}")
  end

  test "retrieve keeps a legacy upstream message but drops the remaining private fields" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, "dispatch-legacy-error-projection")

    {:ok, message} =
      start_stateful_message(agent.uid, conversation, "legacy-error-projection", [
        text_message("user", "hello")
      ])

    assert :ok =
             StatefulLifecycle.commit_socket_open_error(
               %{message_id: message.id},
               %Ankole.AIGateway.ProviderFailure{
                 kind: :status_rejected,
                 provider_status: 502,
                 provider_body: %{}
               }
             )

    stored = Repo.get!(Message, message.id)

    legacy_error = %{
      "body" => "private provider body",
      "code" => "upstream_response_failed",
      "message" => "private provider message",
      "reason" => "private provider reason",
      "retryable" => true,
      "status" => 502
    }

    stored
    |> Ecto.Changeset.change(metadata: Map.put(stored.metadata, "error", legacy_error))
    |> Repo.update!()

    assert {:ok, %{body: %{"error" => public_error}}} =
             StatefulLifecycle.retrieve_response(agent.uid, "resp_#{message.id}")

    assert public_error == %{
             "code" => "upstream_response_failed",
             "failure_kind" => "provider_response",
             "message" => "private provider message",
             "provider_status" => 502,
             "retryable" => true
           }

    refute Map.has_key?(public_error, "body")
    refute Map.has_key?(public_error, "reason")
    refute Map.has_key?(public_error, "status")
  end
end
