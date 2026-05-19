defmodule BullX.AIAgent.TargetTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{ACL, AmbientBatch, Conversation, Conversations, Message}
  alias BullX.AuthZ
  alias BullX.EventBus
  alias BullX.EventBus.{RuleWriter, TargetSession, TargetSessionEntry, TestingChannel}
  alias BullX.EventBus.TargetSession.Worker
  alias BullX.LLM.{PluginProviders, Writer}
  alias BullX.Plugins.{Discovery, Registry}
  alias BullX.Principals

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    allow_catalog_cache()
    BullX.LLM.Catalog.Cache.refresh_all()

    previous_llm = Application.get_env(:bullx, :llm, [])
    previous_adapter_registry = Application.get_env(:bullx, :event_bus_channel_adapter_registry)
    previous_delivery_gate = Application.get_env(:bullx, :event_bus_test_delivery_gate)
    previous_pid = Application.get_env(:bullx, :event_bus_test_pid)

    {:ok, plugin} =
      Discovery.discover_app(:eventbus_test_plugin, modules: [BullX.EventBus.TestAdapterPlugin])

    registry = :"ai_agent_target_adapter_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["eventbus_test_plugin"], name: registry}
    )

    Application.put_env(
      :bullx,
      :llm,
      Keyword.put(previous_llm, :client, BullX.AIAgent.FakeLLMClient)
    )

    Application.put_env(:bullx, :event_bus_channel_adapter_registry, registry)
    Application.put_env(:bullx, :event_bus_test_pid, self())
    TestingChannel.clear()

    BullX.AIAgent.FakeLLMClient.reset()

    {:ok, _provider} =
      Writer.put_provider(%{
        provider_id: "openai_proxy",
        req_llm_provider: "openai",
        api_key: "sk-test",
        provider_options: %{"auth_mode" => "api_key"}
      })

    on_exit(fn ->
      Application.put_env(:bullx, :llm, previous_llm)
      restore_env(:event_bus_channel_adapter_registry, previous_adapter_registry)
      restore_env(:event_bus_test_delivery_gate, previous_delivery_gate)
      restore_env(:event_bus_test_pid, previous_pid)
      BullX.AIAgent.FakeLLMClient.reset()
      BullX.LLM.Catalog.Cache.refresh_all()
    end)

    :ok
  end

  test "addressed IM events append user and assistant messages inside one conversation" do
    {:ok, agent} = create_ai_agent("ai-agent-target-addressed")
    {:ok, caller} = create_human("ai-agent-target-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("hello back")

    invocation = invocation(agent.id)
    entry = addressed_entry(invocation.target_session_id, "evt-addressed-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}
    refute_received {:failed, _reason}

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    assert conversation.agent_principal_id == agent.id

    messages =
      Message
      |> where([m], m.conversation_id == ^conversation.id)
      |> order_by([m], asc: m.inserted_at)
      |> Repo.all()

    assert [
             %Message{role: :user, kind: :normal, content: [%{"text" => "hello"}]},
             %Message{
               role: :assistant,
               kind: :normal,
               content: [%{"text" => "hello back"}],
               metadata: %{
                 "delivery" => %{"status" => "sent", "safe_error_code" => nil},
                 "usage_source" => "provider_reported"
               }
             }
           ] = messages
  end

  test "streaming reply channel keeps final assistant output on the stream surface" do
    {:ok, agent} = create_ai_agent("ai-agent-target-streaming")
    {:ok, caller} = create_human("ai-agent-target-streaming-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("streamed answer")

    invocation = invocation(agent.id)

    entry =
      invocation.target_session_id
      |> addressed_entry("evt-streaming-1", "hello", caller.id)
      |> put_in([:cloud_event, "data", "reply_channel", "delivery_mode"], "stream")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_stream_consumed, _source, _reply_channel, _stream_id}
    refute_receive {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}, 50
    refute_received {:failed, _reason}

    assert %Message{
             role: :assistant,
             status: :complete,
             content: [%{"text" => "streamed answer"}],
             metadata: %{"delivery" => %{"mode" => "stream"}}
           } = Repo.one!(from m in Message, where: m.role == :assistant)
  end

  test "addressed IM events project normalized rich input into transcript text" do
    {:ok, agent} = create_ai_agent("ai-agent-target-rich-input")
    {:ok, caller} = create_human("ai-agent-target-rich-input-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("rich input received")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-rich-input-1", "plain", caller.id)
      |> put_in(
        [:cloud_event, "data", "content"],
        [
          %{"type" => "text", "text" => "plain"},
          %{
            "type" => "card",
            "format" => "feishu.card",
            "fallback_text" => "Approval request",
            "payload" => %{"private" => "not transcript"}
          },
          %{
            "type" => "action",
            "action_id" => "approve",
            "text" => "submitted action: approve",
            "values" => %{"decision" => "yes"}
          },
          %{
            "type" => "file",
            "url" => "feishu://message-resource/om_1/file",
            "fallback_text" => "contract.pdf"
          }
        ]
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}

    assert %Message{
             role: :user,
             kind: :normal,
             content: [
               %{"type" => "text", "text" => "plain"},
               %{"type" => "text", "text" => "Approval request"},
               %{"type" => "text", "text" => "submitted action: approve"},
               %{"type" => "text", "text" => "contract.pdf"}
             ]
           } = Repo.one!(from m in Message, where: m.role == :user)
  end

  test "directed action events enter the normal user turn" do
    {:ok, agent} = create_ai_agent("ai-agent-target-action")
    {:ok, caller} = create_human("ai-agent-target-action-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("approval recorded")

    invocation = invocation(agent.id)

    entry =
      entry(
        invocation.target_session_id,
        "evt-action-1",
        "bullx.action.submitted",
        "submitted action: approve",
        caller.id
      )
      |> put_in(
        [:cloud_event, "data", "content"],
        [
          %{
            "type" => "action",
            "action_id" => "approve",
            "text" => "submitted action: approve",
            "values" => %{"decision" => "yes"}
          }
        ]
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}

    assert %Message{
             role: :user,
             kind: :normal,
             content: [%{"type" => "text", "text" => "submitted action: approve"}]
           } = Repo.one!(from m in Message, where: m.role == :user)
  end

  test "conversation key requires normalized CloudEvent data" do
    {:ok, agent} = create_ai_agent("ai-agent-target-routing-context")
    {:ok, caller} = create_human("ai-agent-routing-context-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("fallback ok")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-routing-context-1", "hello", caller.id)

    data = entry.cloud_event["data"]

    entry = %{
      entry
      | cloud_event:
          put_in(entry.cloud_event, ["data"], Map.drop(data, ["channel", "scope", "actor"])),
        routing_context:
          entry.routing_context
          |> Map.merge(Map.take(data, ["channel", "scope", "actor"]))
    }

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received {:failed, :invalid_conversation_key}
    refute_received :closed
    refute_received {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}
    assert Repo.aggregate(Conversation, :count) == 0
  end

  test "missing provider usage is marked as estimated metadata" do
    {:ok, agent} = create_ai_agent("ai-agent-target-estimated-usage")
    {:ok, caller} = create_human("ai-agent-estimated-usage-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("no usage", [], usage: nil)

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-estimated-usage-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}

    assert %Message{metadata: %{"usage" => nil, "usage_source" => "estimated"}} =
             Repo.one!(from m in Message, where: m.role == :assistant)
  end

  test "assistant metadata normalizes finish reason and provider diagnostics" do
    {:ok, agent} = create_ai_agent("ai-agent-target-provider-diagnostics")
    {:ok, caller} = create_human("ai-agent-provider-diagnostics-caller")
    grant(caller.id, agent.id, "invoke")

    BullX.AIAgent.FakeLLMClient.push_response("diagnostics", [],
      finish_reason: "end_turn",
      provider_meta: %{
        "request_id" => "req-1",
        "response_id" => "resp-1",
        "api_key" => "must-not-persist"
      }
    )

    invocation = invocation(agent.id)

    entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-provider-diagnostics-1",
        "hello",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)

    assert %Message{
             metadata: %{
               "finish_reason" => "stop",
               "provider_diagnostics" => %{"request_id" => "req-1", "response_id" => "resp-1"}
             }
           } = Repo.one!(from m in Message, where: m.role == :assistant)
  end

  test "tool loop persists ordered tool results before visible follow-up" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-tool-loop", %{
        "toolsets" => %{"web_research" => %{"enabled" => true}}
      })

    {:ok, caller} = create_human("ai-agent-tool-loop-caller")
    grant(caller.id, agent.id, "invoke")

    BullX.AIAgent.FakeLLMClient.push_response("", [
      %{"id" => "call_1", "name" => "web_search", "arguments" => %{"query" => "alpha"}},
      %{"id" => "call_2", "name" => "web_search", "arguments" => %{"query" => "beta"}}
    ])

    BullX.AIAgent.FakeLLMClient.push_response("tools complete")

    invocation = invocation(agent.id)
    entry = addressed_entry(invocation.target_session_id, "evt-tool-loop-1", "search", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:event_bus_adapter_delivered, _source, _reply_channel, outbound}
    assert get_in(outbound, ["content", Access.at(0), "body", "text"]) == "tools complete"

    assert %Message{role: :tool, content: tool_results} =
             Repo.one!(from m in Message, where: m.role == :tool)

    assert Enum.map(tool_results, & &1["tool_call_id"]) == ["call_1", "call_2"]
    assert Enum.all?(tool_results, &(&1["is_error"] == false))
  end

  test "denied command sends safe response without writing command messages" do
    {:ok, agent} = create_ai_agent("ai-agent-target-command-denied")
    {:ok, caller} = create_human("ai-agent-command-denied-caller")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-command-denied-1",
        "/compress",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:event_bus_adapter_delivered, _source, _reply_channel, outbound}
    refute_received {:failed, _reason}

    assert [%Conversation{}] = Repo.all(Conversation)
    assert [] = Repo.all(Message)

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "Command denied.",
                 "short_text" => "Denied"
               }
             }
           ] = outbound["content"]
  end

  test "retry recalls the previous delivered assistant message before replacement output" do
    {:ok, agent} = create_ai_agent("ai-agent-target-retry-recall")
    {:ok, caller} = create_human("ai-agent-target-retry-recall-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-retry-recall-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, old_outbound}

    old_external_id = "external:" <> old_outbound["id"]

    BullX.AIAgent.FakeLLMClient.push_response("new answer")

    retry_entry =
      addressed_entry(invocation.target_session_id, "evt-retry-recall-2", "/retry", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{"op" => "recall", "target_external_id" => ^old_external_id}}

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, new_outbound}
    assert get_in(new_outbound, ["content", Access.at(0), "body", "text"]) == "new answer"
  end

  test "retry sends control notice before replacement output when old answer is not recallable" do
    {:ok, agent} = create_ai_agent("ai-agent-target-retry-no-recall")
    {:ok, caller} = create_human("ai-agent-target-retry-no-recall-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-retry-no-recall-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _old_outbound}

    assistant = Repo.one!(from m in Message, where: m.role == :assistant)

    {:ok, _message} =
      Conversations.update_message(assistant, %{
        metadata: Map.delete(assistant.metadata, "delivery")
      })

    BullX.AIAgent.FakeLLMClient.push_response("new answer")

    retry_entry =
      addressed_entry(invocation.target_session_id, "evt-retry-no-recall-2", "/retry", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, feedback_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "Retrying the last exchange.",
                 "short_text" => "Retrying"
               }
             }
           ] = feedback_outbound["content"]

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, new_outbound}
    assert get_in(new_outbound, ["content", Access.at(0), "body", "text"]) == "new answer"
  end

  test "undo recalls the previous delivered assistant message without extra feedback" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-feedback")
    {:ok, caller} = create_human("ai-agent-target-undo-feedback-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("answer to undo")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-undo-feedback-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, old_outbound}

    old_external_id = "external:" <> old_outbound["id"]

    undo_entry =
      addressed_entry(invocation.target_session_id, "evt-undo-feedback-2", "/undo", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{"op" => "recall", "target_external_id" => ^old_external_id}}

    refute_receive {:event_bus_adapter_delivered, _source, _reply_channel, _feedback_outbound}, 50
  end

  test "retry after undo retries the previous exchange on the active branch" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-then-retry-previous")
    {:ok, caller} = create_human("ai-agent-target-undo-then-retry-previous-caller")
    grant(caller.id, agent.id, "invoke")
    invocation = invocation(agent.id)

    BullX.AIAgent.FakeLLMClient.push_response("first answer")

    first_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-undo-retry-previous-1",
        "first",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, first_outbound}
    first_external_id = "external:" <> first_outbound["id"]

    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    second_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-undo-retry-previous-2",
        "second",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, second_outbound}
    second_external_id = "external:" <> second_outbound["id"]

    undo_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-undo-retry-previous-3",
        "/undo",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{"op" => "recall", "target_external_id" => ^second_external_id}}

    BullX.AIAgent.FakeLLMClient.push_response("first answer retried")

    retry_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-undo-retry-previous-4",
        "/retry",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{"op" => "recall", "target_external_id" => ^first_external_id}}

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, retry_outbound}

    assert get_in(retry_outbound, ["content", Access.at(0), "body", "text"]) ==
             "first answer retried"

    refute_received {:failed, _reason}
  end

  test "retry after undoing the only exchange returns a no retry target notice" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-then-retry-empty")
    {:ok, caller} = create_human("ai-agent-target-undo-then-retry-empty-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("answer to undo")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-undo-retry-empty-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, old_outbound}
    old_external_id = "external:" <> old_outbound["id"]

    undo_entry =
      addressed_entry(invocation.target_session_id, "evt-undo-retry-empty-2", "/undo", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{"op" => "recall", "target_external_id" => ^old_external_id}}

    retry_entry =
      addressed_entry(invocation.target_session_id, "evt-undo-retry-empty-3", "/retry", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, feedback_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "There is no previous assistant reply to retry.",
                 "short_text" => "No Retry"
               }
             }
           ] = feedback_outbound["content"]

    refute_receive {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}, 50
    refute_received {:failed, _reason}
  end

  test "undo sends control notice when there is no recallable assistant message" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-no-recall")
    {:ok, caller} = create_human("ai-agent-target-undo-no-recall-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("answer without delivery metadata")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-undo-no-recall-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _old_outbound}

    assistant = Repo.one!(from m in Message, where: m.role == :assistant)
    {:ok, _message} = Conversations.update_message(assistant, %{metadata: %{}})

    undo_entry =
      addressed_entry(invocation.target_session_id, "evt-undo-no-recall-2", "/undo", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, feedback_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "Undid the last exchange.",
                 "short_text" => "Undone"
               }
             }
           ] = feedback_outbound["content"]
  end

  test "stop recalls unfinished visible output without extra feedback" do
    {:ok, agent} = create_ai_agent("ai-agent-target-stop-recall")
    {:ok, caller} = create_human("ai-agent-target-stop-recall-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("initial answer")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-stop-recall-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _initial_outbound}

    conversation = Repo.one!(Conversation)
    user = Repo.one!(from m in Message, where: m.role == :user)
    {:ok, leased, lease_id} = acquire_test_generation(conversation, user.id)

    {:ok, _conversation, _generating} =
      Conversations.append_message(leased, %{
        conversation_id: leased.id,
        role: :assistant,
        kind: :normal,
        status: :generating,
        content: [],
        metadata: %{
          "generation" => %{"lease_id" => lease_id, "source_message_id" => user.id},
          "delivery" => delivery_metadata("om_streaming"),
          "stream" => %{"stream_id" => "stream_stop_recall", "status" => "open"}
        }
      })

    stop_entry =
      addressed_entry(invocation.target_session_id, "evt-stop-recall-2", "/stop", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, stop_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{"op" => "recall", "target_external_id" => "om_streaming"}}

    refute_receive {:event_bus_adapter_delivered, _source, _reply_channel, _feedback_outbound}, 50
  end

  test "stop sends control notice when unfinished output is not recallable" do
    {:ok, agent} = create_ai_agent("ai-agent-target-stop-no-recall")
    {:ok, caller} = create_human("ai-agent-target-stop-no-recall-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("initial answer")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-stop-no-recall-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _initial_outbound}

    conversation = Repo.one!(Conversation)
    user = Repo.one!(from m in Message, where: m.role == :user)
    {:ok, leased, lease_id} = acquire_test_generation(conversation, user.id)

    {:ok, _conversation, _generating} =
      Conversations.append_message(leased, %{
        conversation_id: leased.id,
        role: :assistant,
        kind: :normal,
        status: :generating,
        content: [],
        metadata: %{
          "generation" => %{"lease_id" => lease_id, "source_message_id" => user.id},
          "stream" => %{"stream_id" => "stream_stop_no_recall", "status" => "open"}
        }
      })

    stop_entry =
      addressed_entry(invocation.target_session_id, "evt-stop-no-recall-2", "/stop", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, stop_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, feedback_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "Stopped generation.",
                 "short_text" => "Stopped"
               }
             }
           ] = feedback_outbound["content"]
  end

  test "steer sends control notice feedback without writing command messages" do
    {:ok, agent} = create_ai_agent("ai-agent-target-steer-feedback")
    {:ok, caller} = create_human("ai-agent-target-steer-feedback-caller")
    grant(caller.id, agent.id, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("initial answer")

    invocation = invocation(agent.id)

    entry =
      addressed_entry(invocation.target_session_id, "evt-steer-feedback-1", "hello", caller.id)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _initial_outbound}

    conversation = Repo.one!(Conversation)

    {:ok, _leased, _lease_id} =
      Conversations.acquire_generation_lease(
        conversation,
        %{
          "owner_source_type" => "test",
          "owner_source_id" => "steer-feedback",
          "source_message_id" => Repo.one!(from m in Message, where: m.role == :user).id,
          "generation_lease_ttl_ms" => 60_000,
          "generation_heartbeat_interval_ms" => 5_000,
          "generation_max_runtime_ms" => 60_000
        },
        DateTime.utc_now(:microsecond)
      )

    steer_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-steer-feedback-2",
        "/steer focus on the latest constraint",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, steer_entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, steer_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "Steering note received.",
                 "short_text" => "Steered"
               }
             }
           ] = steer_outbound["content"]

    assert Repo.aggregate(Message, :count) == 2
  end

  test "compress sends progress notice and updates it after summary write" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-compress-feedback", %{
        "instructions" => "Answer briefly."
      })

    {:ok, caller} = create_human("ai-agent-target-compress-feedback-caller")
    grant(caller.id, agent.id, "invoke")

    invocation = invocation(agent.id)

    long_text = String.duplicate("compressible context ", 900)

    BullX.AIAgent.FakeLLMClient.push_response("first answer")

    first_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-compress-feedback-1",
        long_text,
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _first_outbound}

    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    second_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-compress-feedback-2",
        long_text,
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _second_outbound}

    BullX.AIAgent.FakeLLMClient.push_response("compressed summary")

    compress_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-compress-feedback-3",
        "/compress",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, compress_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{
                      "op" => "send",
                      "content" => [
                        %{
                          "kind" => "progress_notice",
                          "body" => %{"text" => "正在压缩历史对话..."}
                        }
                      ]
                    } = started_outbound}

    expected_target_external_id = "external:" <> started_outbound["id"]

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{
                      "op" => "edit",
                      "target_external_id" => ^expected_target_external_id,
                      "content" => [
                        %{
                          "kind" => "progress_notice",
                          "body" => %{
                            "text" => "以上历史对话记录已被压缩",
                            "show_divider" => true
                          }
                        }
                      ]
                    }}

    assert %Message{kind: :summary} = Repo.one!(from m in Message, where: m.kind == :summary)
  end

  test "compress no-op updates progress notice without duplicate control notice" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-compress-noop-feedback", %{
        "instructions" => "Answer briefly."
      })

    {:ok, caller} = create_human("ai-agent-target-compress-noop-feedback-caller")
    grant(caller.id, agent.id, "invoke")

    invocation = invocation(agent.id)

    BullX.AIAgent.FakeLLMClient.push_response("short answer")

    first_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-compress-noop-feedback-1",
        "short message",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _first_outbound}

    compress_entry =
      addressed_entry(
        invocation.target_session_id,
        "evt-compress-noop-feedback-2",
        "/compress",
        caller.id
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, compress_entry)
    assert_received :closed

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{
                      "op" => "send",
                      "content" => [
                        %{
                          "kind" => "progress_notice",
                          "body" => %{"text" => "正在压缩历史对话..."}
                        }
                      ]
                    } = started_outbound}

    expected_target_external_id = "external:" <> started_outbound["id"]

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel,
                    %{
                      "op" => "edit",
                      "target_external_id" => ^expected_target_external_id,
                      "content" => [
                        %{
                          "kind" => "progress_notice",
                          "body" => %{
                            "text" => "没有可压缩的历史对话",
                            "show_divider" => false
                          }
                        }
                      ]
                    }}

    refute_receive {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}, 50
    assert [] = Repo.all(from m in Message, where: m.kind == :summary)
  end

  test "target session queues steer behind in-flight compression feedback" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-compress-queue", %{
        "instructions" => "Answer briefly."
      })

    {:ok, caller} = create_human("ai-agent-target-compress-queue-caller")
    grant(caller.id, agent.id, "invoke")

    invocation = invocation(agent.id)
    long_text = String.duplicate("compressible context ", 900)

    BullX.AIAgent.FakeLLMClient.push_response("first answer")

    assert :ok =
             BullX.AIAgent.handle_event(
               invocation,
               addressed_entry(
                 invocation.target_session_id,
                 "evt-compress-queue-seed-1",
                 long_text,
                 caller.id
               )
             )

    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _first_outbound}

    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    assert :ok =
             BullX.AIAgent.handle_event(
               invocation,
               addressed_entry(
                 invocation.target_session_id,
                 "evt-compress-queue-seed-2",
                 long_text,
                 caller.id
               )
             )

    assert_received :closed
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, _second_outbound}

    {:ok, _route} = create_addressed_route(agent.id, "ai agent compression queue target")

    block_ref = TestingChannel.block_next_delivery(:progress_notice)

    assert {:ok, accepted_compress} =
             EventBus.accept(addressed_bus_event("evt-compress-queue-1", "/compress", caller))

    worker =
      Task.async(fn ->
        Worker.perform(%Oban.Job{
          args: %{"target_session_id" => accepted_compress.target_session_id}
        })
      end)

    assert {:ok, blocked} = TestingChannel.await_blocked_delivery(block_ref)

    assert get_in(blocked.outbound, ["content", Access.at(0), "kind"]) == "progress_notice"

    assert get_in(blocked.outbound, ["content", Access.at(0), "body", "text"]) ==
             "正在压缩历史对话..."

    assert %TargetSession{last_processed_entry_seq: 0} =
             Repo.get!(TargetSession, accepted_compress.target_session_id)

    assert {:ok, accepted_steer} =
             EventBus.accept(
               addressed_bus_event(
                 "evt-compress-queue-2",
                 "/steer use this only if a live loop exists",
                 caller
               )
             )

    assert accepted_steer.target_session_id == accepted_compress.target_session_id
    refute_receive {:event_bus_adapter_delivered, _source, _reply_channel, _outbound}, 50

    assert :ok = TestingChannel.release_delivery(blocked)
    assert :ok = Task.await(worker, 5_000)

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, started_outbound}
    assert get_in(started_outbound, ["content", Access.at(0), "kind"]) == "progress_notice"

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, finished_outbound}
    assert finished_outbound["op"] == "edit"
    assert get_in(finished_outbound, ["content", Access.at(0), "body", "show_divider"]) == true

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, steer_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "There is no active generation.",
                 "short_text" => "Idle"
               }
             }
           ] = steer_outbound["content"]

    steer_entry = Repo.get!(TargetSessionEntry, accepted_steer.side_channel_entry_id)

    assert %TargetSession{last_processed_entry_seq: processed_seq, status: :closed} =
             Repo.get!(TargetSession, accepted_compress.target_session_id)

    assert processed_seq == steer_entry.entry_seq
    assert %Message{kind: :summary} = Repo.one!(from m in Message, where: m.kind == :summary)
  end

  test "EventBus command fallback sends normalized slash commands to the addressed AIAgent route" do
    {:ok, agent} = create_ai_agent("ai-agent-target-command-fallback")
    {:ok, caller} = create_human("ai-agent-command-fallback-caller")
    grant(caller.id, agent.id, "invoke")

    {:ok, route} = create_addressed_route(agent.id, "ai agent addressed fallback target")

    assert {:ok, accepted} = EventBus.accept(command_event("new", caller))
    assert accepted.rule_id == route.id

    assert :ok =
             Worker.perform(%Oban.Job{args: %{"target_session_id" => accepted.target_session_id}})

    session = Repo.get!(TargetSession, accepted.target_session_id)
    entry = Repo.get!(TargetSessionEntry, accepted.side_channel_entry_id)

    assert session.status == :closed
    assert entry.cloud_event["type"] == "bullx.command.invoked"
    assert entry.routing_context["type"] == "bullx.im.message.addressed"

    assert [%Conversation{ended_at: %DateTime{}}, %Conversation{ended_at: nil}] =
             Repo.all(from c in Conversation, order_by: [asc: c.inserted_at])

    assert [] = Repo.all(Message)
    assert_received {:event_bus_adapter_delivered, _source, _reply_channel, outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "Started a new conversation.",
                 "short_text" => "New Session"
               }
             }
           ] = outbound["content"]
  end

  test "ambient observe-only events are recorded but do not invoke generation" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-ambient", %{"unmentioned_group_messages" => "observe_only"})

    BullX.AIAgent.FakeLLMClient.push_response("should not be consumed")

    invocation = invocation(agent.id)
    entry = ambient_entry(invocation.target_session_id, "evt-ambient-1", "background note")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    assert [
             %Message{
               role: :im_ambient,
               kind: :normal,
               content: [%{"text" => "background note"}]
             }
           ] = Repo.all(Message)
  end

  test "long ambient messages store a brief on the same ambient message" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-ambient-brief", %{
        "unmentioned_group_messages" => "observe_only"
      })

    BullX.AIAgent.FakeLLMClient.push_response("short safe brief")

    invocation = invocation(agent.id)
    long_text = String.duplicate("background context ", 80)
    entry = ambient_entry(invocation.target_session_id, "evt-ambient-brief-1", long_text)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    assert [
             %Message{
               role: :im_ambient,
               kind: :normal,
               metadata: %{"brief" => "short safe brief"}
             }
           ] =
             Repo.all(Message)
  end

  test "ambient intervention batches send to the scene without replying to one message" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-ambient-no-reply-anchor", %{
        "unmentioned_group_messages" => "may_intervene"
      })

    invocation = invocation(agent.id)

    entry =
      invocation.target_session_id
      |> ambient_entry("evt-ambient-no-reply-anchor", "background note")
      |> put_in([:cloud_event, "data", "reply_channel"], %{
        "adapter" => "eventbus_test",
        "channel_id" => "default",
        "scope_id" => "scene-1",
        "scope_kind" => "group",
        "reply_to_external_id" => "provider-message-1"
      })

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    batch_key = "#{agent.id}:#{conversation.id}"

    assert {:ok, meta, _items} = AmbientBatch.take(batch_key)
    refute Map.has_key?(meta["reply_channel"], "reply_to_external_id")
    assert meta["reply_channel"]["scope_id"] == "scene-1"

    AmbientBatch.cleanup(batch_key)
  end

  test "ambient intervention batches use a short window when text names the agent" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-ambient-agent-name", %{
        "unmentioned_group_messages" => "may_intervene"
      })

    invocation = invocation(agent.id)

    entry =
      ambient_entry(invocation.target_session_id, "evt-ambient-agent-name", "#{agent.uid} 看一下")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    batch_key = "#{agent.id}:#{conversation.id}"

    assert {:ok, meta, _items} = AmbientBatch.take(batch_key)
    assert meta["due_at"] - System.system_time(:millisecond) <= 5_000

    AmbientBatch.cleanup(batch_key)
  end

  test "ambient intervention shortens an open batch after the agent has answered" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-ambient-after-answer", %{
        "unmentioned_group_messages" => "may_intervene"
      })

    invocation = invocation(agent.id)

    first_entry =
      ambient_entry(invocation.target_session_id, "evt-ambient-after-answer-1", "first")

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)

    assert {:ok, _conversation, _assistant} =
             Conversations.append_message(conversation, %{
               conversation_id: conversation.id,
               role: :assistant,
               kind: :normal,
               status: :complete,
               content: [Message.text_block("bot answer")],
               metadata: %{}
             })

    second_entry =
      ambient_entry(invocation.target_session_id, "evt-ambient-after-answer-2", "follow up")

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    refute_received {:failed, _reason}

    batch_key = "#{agent.id}:#{conversation.id}"

    assert {:ok, meta, items} = AmbientBatch.take(batch_key)
    assert meta["due_at"] - System.system_time(:millisecond) <= 5_000
    assert Enum.map(items, & &1["text"]) == ["first", "follow up"]

    AmbientBatch.cleanup(batch_key)
  end

  test "unsupported events close the invocation without creating business records" do
    {:ok, agent} = create_ai_agent("ai-agent-target-unsupported")
    invocation = invocation(agent.id)
    entry = unsupported_entry(invocation.target_session_id, "evt-unsupported-1")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}
    assert [] = Repo.all(Conversation)
    assert [] = Repo.all(Message)
  end

  defp create_addressed_route(agent_principal_id, name) do
    RuleWriter.create_rule(%{
      name: name,
      priority: 1000,
      match_expr:
        ~s(type == "bullx.im.message.addressed" && channel.adapter == "eventbus_test" && channel.id == "default"),
      target_type: :ai_agent,
      target_ref: agent_principal_id,
      scope_fields: ["channel.adapter", "channel.id", "scope.id"],
      window_type: :rolling_ttl,
      window_ttl_seconds: 3600
    })
  end

  defp acquire_test_generation(conversation, source_message_id) do
    Conversations.acquire_generation_lease(
      conversation,
      %{
        "owner_source_type" => "test",
        "owner_source_id" => "stop-test",
        "source_message_id" => source_message_id,
        "generation_lease_ttl_ms" => 60_000,
        "generation_heartbeat_interval_ms" => 5_000,
        "generation_max_runtime_ms" => 60_000
      },
      DateTime.utc_now(:microsecond)
    )
  end

  defp delivery_metadata(external_id) do
    %{
      "status" => "sent",
      "adapter_result_ref" =>
        Jason.encode!(%{
          "primary_external_id" => external_id,
          "external_message_ids" => [external_id]
        })
    }
  end

  defp create_ai_agent(uid, overrides \\ %{}) do
    profile =
      Map.merge(
        %{
          "main_model" => "openai_proxy:gpt-test",
          "instructions" => "Answer briefly.",
          "context" => %{"max_turns" => 3}
        },
        overrides
      )

    {:ok, %{principal: principal}} =
      Principals.create_agent(%{
        uid: uid,
        display_name: uid,
        profile: %{"ai_agent" => profile}
      })

    {:ok, principal}
  end

  defp create_human(uid) do
    {:ok, %{principal: principal}} =
      Principals.create_human(%{uid: uid, display_name: uid, email: "#{uid}@example.com"})

    {:ok, principal}
  end

  defp grant(caller_principal_id, agent_principal_id, action) do
    AuthZ.create_permission_grant(%{
      principal_id: caller_principal_id,
      resource_pattern: ACL.resource(agent_principal_id),
      action: action
    })
  end

  defp invocation(agent_principal_id) do
    %{
      target_session_id: BullX.Ext.gen_uuid_v7(),
      event_routing_rule_id: BullX.Ext.gen_uuid_v7(),
      target_type: :ai_agent,
      target_ref: agent_principal_id,
      scope_key: "scope",
      window_key: "window",
      output: BullX.EventBus.StreamingOutput,
      close: fn -> send(self(), :closed) end,
      fail: fn reason -> send(self(), {:failed, reason}) end
    }
  end

  defp addressed_entry(target_session_id, event_id, text, caller_principal_id) do
    entry(target_session_id, event_id, "bullx.im.message.addressed", text, caller_principal_id)
  end

  defp ambient_entry(target_session_id, event_id, text) do
    entry(target_session_id, event_id, "bullx.im.message.ambient", text)
  end

  defp unsupported_entry(target_session_id, event_id) do
    entry(target_session_id, event_id, "example.unsupported", "ignored")
  end

  defp command_event(command_name, caller) do
    %{
      "specversion" => "1.0",
      "id" => "evt-command-fallback-#{command_name}",
      "source" => "test://source/default",
      "type" => "bullx.command.invoked",
      "time" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
      "datacontenttype" => "application/json",
      "data" => %{
        "content" => [%{"type" => "text", "text" => "/" <> command_name}],
        "channel" => %{"adapter" => "eventbus_test", "id" => "default", "kind" => "dm"},
        "scope" => %{"id" => "scene-1", "thread_id" => "thread-1"},
        "actor" => %{
          "external_account_id" => "ou_1",
          "display_name" => "Alice",
          "principal" => %{"id" => caller.id, "type" => "human"}
        },
        "refs" => [],
        "reply_channel" => %{"adapter" => "eventbus_test", "channel_id" => "default"},
        "routing_facts" => %{
          "command_name" => command_name,
          "command_surface" => "slash_text",
          "command_args_kind" => "none"
        },
        "raw_ref" => nil
      }
    }
  end

  defp addressed_bus_event(event_id, text, caller) do
    %{
      "specversion" => "1.0",
      "id" => event_id,
      "source" => "test://source/default",
      "type" => "bullx.im.message.addressed",
      "time" => DateTime.utc_now(:second) |> DateTime.to_iso8601(),
      "datacontenttype" => "application/json",
      "data" => %{
        "content" => [%{"type" => "text", "text" => text}],
        "channel" => %{"adapter" => "eventbus_test", "id" => "default", "kind" => "group"},
        "scope" => %{"id" => "scene-1", "thread_id" => "thread-1"},
        "actor" => %{
          "external_account_id" => "ou_1",
          "display_name" => "Alice",
          "principal" => %{"id" => caller.id, "type" => "human"}
        },
        "refs" => [],
        "reply_channel" => %{"adapter" => "eventbus_test", "channel_id" => "default"},
        "routing_facts" => %{},
        "raw_ref" => nil
      }
    }
  end

  defp entry(target_session_id, event_id, event_type, text, caller_principal_id \\ nil) do
    %{
      id: BullX.Ext.gen_uuid_v7(),
      entry_seq: 1,
      target_session_id: target_session_id,
      event_source: "/feishu",
      event_id: event_id,
      cloud_event: %{
        "id" => event_id,
        "source" => "/feishu",
        "type" => event_type,
        "data" => %{
          "content" => [%{"type" => "text", "text" => text}],
          "channel" => %{
            "adapter" => "eventbus_test",
            "id" => "default",
            "kind" => "group"
          },
          "scope" => %{"id" => "scene-1", "thread_id" => "thread-1"},
          "actor" => %{
            "external_account_id" => "ou_1",
            "display_name" => "Alice",
            "principal" => nil
          },
          "refs" => [],
          "reply_channel" => %{"adapter" => "eventbus_test", "channel_id" => "default"},
          "routing_facts" => %{},
          "raw_ref" => nil
        }
      },
      routing_context: routing_context(caller_principal_id),
      appended_at: DateTime.utc_now(:microsecond)
    }
  end

  defp routing_context(nil), do: %{}
  defp routing_context(principal_id), do: %{"triggering_principal_id" => principal_id}

  defp allow_catalog_cache do
    case GenServer.whereis(BullX.LLM.Catalog.Cache) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), pid)
      nil -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
