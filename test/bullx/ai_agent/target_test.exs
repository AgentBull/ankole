defmodule BullX.AIAgent.TargetTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{ACL, AmbientBatch, Conversation, Conversations, Event, Message}
  alias BullX.AuthZ
  alias BullX.IMGateway.TestingChannel
  alias BullX.LLM.{PluginProviders, Writer}
  alias BullX.MailBox.Entry
  alias BullX.Plugins.{Discovery, Registry}
  alias BullX.Principals

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    allow_catalog_cache()
    BullX.LLM.Catalog.Cache.refresh_all()

    previous_llm = Application.get_env(:bullx, :llm, [])
    previous_ai_agent = Application.get_env(:bullx, :ai_agent)
    previous_web_req_options = Application.get_env(:bullx, :ai_agent_web_req_options)
    previous_adapter_registry = Application.get_env(:bullx, :im_gateway_channel_adapter_registry)
    previous_delivery_gate = Application.get_env(:bullx, :im_gateway_test_delivery_gate)
    previous_stream_error = Application.get_env(:bullx, :im_gateway_test_stream_error)
    previous_pid = Application.get_env(:bullx, :im_gateway_test_pid)

    {:ok, plugin} =
      Discovery.discover_app(:im_gateway_test_plugin,
        modules: [BullX.IMGateway.TestAdapterPlugin]
      )

    registry = :"ai_agent_target_adapter_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["im_gateway_test_plugin"], name: registry}
    )

    Application.put_env(
      :bullx,
      :llm,
      Keyword.put(previous_llm, :client, BullX.AIAgent.FakeLLMClient)
    )

    Application.put_env(:bullx, :ai_agent,
      web: [search_provider: "exa", exa: [api_key: "sk-exa-test"]]
    )

    Application.put_env(:bullx, :ai_agent_web_req_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:bullx, :im_gateway_channel_adapter_registry, registry)
    Application.put_env(:bullx, :im_gateway_test_pid, self())
    TestingChannel.clear()

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "results" => [
          %{
            "title" => "Result",
            "url" => "https://example.com/result",
            "highlights" => ["stubbed result"]
          }
        ]
      })
    end)

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
      restore_env(:ai_agent, previous_ai_agent)
      restore_env(:ai_agent_web_req_options, previous_web_req_options)
      restore_env(:im_gateway_channel_adapter_registry, previous_adapter_registry)
      restore_env(:im_gateway_test_delivery_gate, previous_delivery_gate)
      restore_env(:im_gateway_test_stream_error, previous_stream_error)
      restore_env(:im_gateway_test_pid, previous_pid)
      BullX.AIAgent.FakeLLMClient.reset()
      BullX.LLM.Catalog.Cache.refresh_all()
    end)

    :ok
  end

  test "addressed IM events append user and assistant messages inside one conversation" do
    {:ok, agent} = create_ai_agent("ai-agent-target-addressed")
    {:ok, caller} = create_human("ai-agent-target-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("hello back")

    invocation = invocation(agent.uid)
    entry = addressed_entry(invocation.mailbox_session_id, "evt-addressed-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}
    refute_received {:failed, _reason}

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    assert conversation.agent_uid == agent.uid

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

    assert %BullX.IMGateway.Message{
             lifecycle_state: :active,
             actor_kind: "agent",
             text: "hello back",
             provider_message_id: provider_message_id
           } =
             Repo.one!(
               from message in BullX.IMGateway.Message, where: message.actor_kind == "agent"
             )

    assert provider_message_id =~ "external:"
  end

  test "streaming reply address keeps final assistant output on the stream surface" do
    {:ok, agent} = create_ai_agent("ai-agent-target-streaming")
    {:ok, caller} = create_human("ai-agent-target-streaming-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("streamed answer")

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-streaming-1", "hello", caller.uid)
      |> put_in([:cloud_event, "data", "reply_address", "delivery_mode"], "stream")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_stream_consumed, _source, _reply_address, _stream_id}
    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}, 50
    refute_received {:failed, _reason}

    assert %Message{
             role: :assistant,
             status: :complete,
             content: [%{"text" => "streamed answer"}],
             metadata: %{"delivery" => %{"mode" => "stream"}}
           } = Repo.one!(from m in Message, where: m.role == :assistant)
  end

  test "streaming reply falls back to final assistant output when stream finalization fails" do
    {:ok, agent} = create_ai_agent("ai-agent-target-streaming-fallback")
    {:ok, caller} = create_human("ai-agent-target-streaming-fallback-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("fallback answer")
    Application.put_env(:bullx, :im_gateway_test_stream_error, %{"kind" => "stream_failed"})

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-streaming-fallback-1", "hello", caller.uid)
      |> put_in([:cloud_event, "data", "reply_address", "delivery_mode"], "stream")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_stream_consumed, _source, _reply_address, _stream_id}
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, fallback_outbound}
    refute_received {:failed, _reason}

    assert %{"op" => "send", "content" => [%{"body" => %{"text" => "fallback answer"}}]} =
             fallback_outbound

    assert %Message{
             role: :assistant,
             status: :complete,
             content: [%{"text" => "fallback answer"}],
             metadata: %{"delivery" => %{"mode" => "outbound", "status" => "sent"}}
           } = Repo.one!(from m in Message, where: m.role == :assistant)
  end

  test "addressed IM events project normalized rich input into transcript text" do
    {:ok, agent} = create_ai_agent("ai-agent-target-rich-input")
    {:ok, caller} = create_human("ai-agent-target-rich-input-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("rich input received")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-rich-input-1", "plain", caller.uid)
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
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

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

  test "action blocks enter through the normal message turn" do
    {:ok, agent} = create_ai_agent("ai-agent-target-action")
    {:ok, caller} = create_human("ai-agent-target-action-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("approval recorded")

    invocation = invocation(agent.uid)

    entry =
      entry(
        invocation.mailbox_session_id,
        "evt-action-1",
        "bullx.message.received",
        "submitted action: approve",
        caller.uid,
        :addressed
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
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    assert %Message{
             role: :user,
             kind: :normal,
             content: [%{"type" => "text", "text" => "submitted action: approve"}]
           } = Repo.one!(from m in Message, where: m.role == :user)
  end

  test "conversation key requires normalized CloudEvent data" do
    {:ok, agent} = create_ai_agent("ai-agent-target-routing-context")
    {:ok, caller} = create_human("ai-agent-routing-context-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("fallback ok")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-routing-context-1", "hello", caller.uid)

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
    refute_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}
    assert Repo.aggregate(Conversation, :count) == 0
  end

  test "missing provider usage is marked as estimated metadata" do
    {:ok, agent} = create_ai_agent("ai-agent-target-estimated-usage")
    {:ok, caller} = create_human("ai-agent-estimated-usage-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("no usage", [], usage: nil)

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-estimated-usage-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    assert %Message{metadata: %{"usage" => nil, "usage_source" => "estimated"}} =
             Repo.one!(from m in Message, where: m.role == :assistant)
  end

  test "assistant metadata normalizes finish reason and provider diagnostics" do
    {:ok, agent} = create_ai_agent("ai-agent-target-provider-diagnostics")
    {:ok, caller} = create_human("ai-agent-provider-diagnostics-caller")
    grant(caller.uid, agent.uid, "invoke")

    BullX.AIAgent.FakeLLMClient.push_response("diagnostics", [],
      finish_reason: "end_turn",
      provider_meta: %{
        "request_id" => "req-1",
        "response_id" => "resp-1",
        "api_key" => "must-not-persist"
      }
    )

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-provider-diagnostics-1",
        "hello",
        caller.uid
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
        "toolsets" => %{"web" => %{"enabled" => true}}
      })

    {:ok, caller} = create_human("ai-agent-tool-loop-caller")
    grant(caller.uid, agent.uid, "invoke")

    BullX.AIAgent.FakeLLMClient.push_response("", [
      %{"id" => "call_1", "name" => "web_search", "arguments" => %{"query" => "alpha"}},
      %{"id" => "call_2", "name" => "web_search", "arguments" => %{"query" => "beta"}}
    ])

    BullX.AIAgent.FakeLLMClient.push_response("tools complete")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-tool-loop-1", "search", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, outbound}
    assert get_in(outbound, ["content", Access.at(0), "body", "text"]) == "tools complete"

    assert %Message{role: :tool, content: tool_results} =
             Repo.one!(from m in Message, where: m.role == :tool)

    assert Enum.map(tool_results, & &1["tool_call_id"]) == ["call_1", "call_2"]
    assert Enum.all?(tool_results, &(&1["is_error"] == false))
  end

  test "streaming tool loop uses one visible stream for one external turn" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-streaming-tool-loop", %{
        "toolsets" => %{"web" => %{"enabled" => true}}
      })

    {:ok, caller} = create_human("ai-agent-streaming-tool-loop-caller")
    grant(caller.uid, agent.uid, "invoke")

    BullX.AIAgent.FakeLLMClient.push_response("", [
      %{"id" => "call_1", "name" => "web_search", "arguments" => %{"query" => "alpha"}}
    ])

    BullX.AIAgent.FakeLLMClient.push_response("tools complete")

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-streaming-tool-loop-1", "search", caller.uid)
      |> put_in([:cloud_event, "data", "reply_address", "delivery_mode"], "stream")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_stream_consumed, _source, _reply_address, stream_id}
    refute_receive {:im_gateway_adapter_stream_consumed, _source, _reply_address, _stream_id}, 50
    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}, 50
    refute_received {:failed, _reason}

    messages =
      Message
      |> order_by([m], asc: m.inserted_at, asc: m.id)
      |> Repo.all()

    assert [
             %Message{role: :user},
             %Message{role: :assistant, content: [%{"type" => "tool_call"}]} = tool_call_message,
             %Message{role: :tool, content: tool_results},
             %Message{
               role: :assistant,
               content: [%{"type" => "text", "text" => "tools complete"}],
               metadata: %{
                 "delivery" => %{"mode" => "stream", "stream_id" => ^stream_id},
                 "stream" => %{"status" => "completed"}
               }
             }
           ] = messages

    refute get_in(tool_call_message.metadata, ["delivery", "mode"]) == "stream"
    assert [%{"is_error" => false, "tool_call_id" => "call_1"}] = tool_results
  end

  test "streaming generation failure after tool results preserves the provider reason" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-streaming-generation-failure", %{
        "toolsets" => %{"web" => %{"enabled" => true}}
      })

    {:ok, caller} = create_human("ai-agent-streaming-generation-failure-caller")
    grant(caller.uid, agent.uid, "invoke")

    BullX.AIAgent.FakeLLMClient.push_response("", [
      %{"id" => "call_1", "name" => "web_search", "arguments" => %{"query" => "alpha"}}
    ])

    BullX.AIAgent.FakeLLMClient.push_error(
      RuntimeError.exception("openrouter stream closed before tool-call response")
    )

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-streaming-generation-failure-1", "search", caller.uid)
      |> put_in([:cloud_event, "data", "reply_address", "delivery_mode"], "stream")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_stream_consumed, _source, _reply_address, stream_id}
    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}, 50
    refute_received {:failed, _reason}

    expected_reason = "RuntimeError: openrouter stream closed before tool-call response"

    assert {:ok, %{status: :failed, chunks: []}} =
             BullX.MailBox.StreamingOutput.resume_stream(stream_id, nil)

    assert {:ok, ^expected_reason} =
             BullX.Redis.command([
               "HGET",
               "bullx:stream:#{stream_id}:meta",
               "terminal_reason"
             ])

    assert %Message{
             role: :assistant,
             kind: :error,
             metadata: %{
               "safe_error_code" => "generation_failed",
               "safe_error_reason" => ^expected_reason
             }
           } =
             Repo.one!(
               from m in Message,
                 where: m.role == :assistant and m.kind == :error,
                 order_by: [desc: m.inserted_at],
                 limit: 1
             )
  end

  test "clarify requested stops the current generation and delivers the question" do
    {:ok, agent} = create_ai_agent("ai-agent-target-clarify")
    {:ok, caller} = create_human("ai-agent-clarify-caller")
    grant(caller.uid, agent.uid, "invoke")

    BullX.AIAgent.FakeLLMClient.push_response("", [
      %{
        "id" => "call_1",
        "name" => "clarify",
        "arguments" => %{
          "question" => "Which account should I use?",
          "choices" => ["Alpha", "Beta", "", "Gamma", "Delta", "Epsilon"]
        }
      }
    ])

    invocation = invocation(agent.uid)
    entry = addressed_entry(invocation.mailbox_session_id, "evt-clarify-1", "start", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, outbound}
    text = get_in(outbound, ["content", Access.at(0), "body", "text"])
    assert text =~ "Which account should I use?"
    assert text =~ "1. Alpha"

    assert %Message{role: :tool, content: [result_block]} =
             Repo.one!(from m in Message, where: m.role == :tool)

    assert get_in(result_block, ["result", "status"]) == "requested"
    assert get_in(result_block, ["result", "choices"]) == ["Alpha", "Beta", "Gamma", "Delta"]

    assert Repo.aggregate(from(m in Message, where: m.role == :assistant), :count) == 1
  end

  test "clarify action answer appends as a normal message and runs" do
    {:ok, agent} = create_ai_agent("ai-agent-target-clarify-action")
    {:ok, caller} = create_human("ai-agent-clarify-action-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("Using Beta.")

    invocation = invocation(agent.uid)

    entry =
      entry(
        invocation.mailbox_session_id,
        "evt-clarify-answer-1",
        "bullx.message.received",
        "Clarification answer: Beta",
        caller.uid,
        :addressed
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, outbound}
    assert get_in(outbound, ["content", Access.at(0), "body", "text"]) == "Using Beta."

    assert %Message{role: :user, content: [%{"text" => "Clarification answer: Beta"}]} =
             Repo.one!(from m in Message, where: m.role == :user)
  end

  test "denied command sends safe response without writing command messages" do
    {:ok, agent} = create_ai_agent("ai-agent-target-command-denied")
    {:ok, caller} = create_human("ai-agent-command-denied-caller")

    invocation = invocation(agent.uid)

    entry =
      command_entry(
        invocation.mailbox_session_id,
        "evt-command-denied-1",
        "/compress",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_received {:im_gateway_adapter_delivered, _source, _reply_address, outbound}
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
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-retry-recall-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, old_outbound}

    old_external_id = "external:" <> old_outbound["id"]

    BullX.AIAgent.FakeLLMClient.push_response("new answer")

    retry_entry =
      command_entry(invocation.mailbox_session_id, "evt-retry-recall-2", "/retry", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
                    %{"op" => "recall", "target_external_id" => ^old_external_id}}

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, new_outbound}
    assert get_in(new_outbound, ["content", Access.at(0), "body", "text"]) == "new answer"
  end

  test "retry sends control notice before replacement output when old answer is not recallable" do
    {:ok, agent} = create_ai_agent("ai-agent-target-retry-no-recall")
    {:ok, caller} = create_human("ai-agent-target-retry-no-recall-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-retry-no-recall-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _old_outbound}

    assistant = Repo.one!(from m in Message, where: m.role == :assistant)

    {:ok, _message} =
      Conversations.update_message(assistant, %{
        metadata: Map.delete(assistant.metadata, "delivery")
      })

    BullX.AIAgent.FakeLLMClient.push_response("new answer")

    retry_entry =
      command_entry(invocation.mailbox_session_id, "evt-retry-no-recall-2", "/retry", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, feedback_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "Retrying the last exchange.",
                 "short_text" => "Retrying"
               }
             }
           ] = feedback_outbound["content"]

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, new_outbound}
    assert get_in(new_outbound, ["content", Access.at(0), "body", "text"]) == "new answer"
  end

  test "undo recalls the previous delivered assistant message without extra feedback" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-feedback")
    {:ok, caller} = create_human("ai-agent-target-undo-feedback-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("answer to undo")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-undo-feedback-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, old_outbound}

    old_external_id = "external:" <> old_outbound["id"]

    undo_entry =
      command_entry(invocation.mailbox_session_id, "evt-undo-feedback-2", "/undo", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
                    %{"op" => "recall", "target_external_id" => ^old_external_id}}

    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _feedback_outbound},
                   50
  end

  test "retry after undo retries the previous visible exchange" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-then-retry-previous")
    {:ok, caller} = create_human("ai-agent-target-undo-then-retry-previous-caller")
    grant(caller.uid, agent.uid, "invoke")
    invocation = invocation(agent.uid)

    BullX.AIAgent.FakeLLMClient.push_response("first answer")

    first_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-undo-retry-previous-1",
        "first",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, first_outbound}
    first_external_id = "external:" <> first_outbound["id"]

    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    second_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-undo-retry-previous-2",
        "second",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, second_outbound}
    second_external_id = "external:" <> second_outbound["id"]

    undo_entry =
      command_entry(
        invocation.mailbox_session_id,
        "evt-undo-retry-previous-3",
        "/undo",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
                    %{"op" => "recall", "target_external_id" => ^second_external_id}}

    BullX.AIAgent.FakeLLMClient.push_response("first answer retried")

    retry_entry =
      command_entry(
        invocation.mailbox_session_id,
        "evt-undo-retry-previous-4",
        "/retry",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
                    %{"op" => "recall", "target_external_id" => ^first_external_id}}

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, retry_outbound}

    assert get_in(retry_outbound, ["content", Access.at(0), "body", "text"]) ==
             "first answer retried"

    refute_received {:failed, _reason}
  end

  test "retry after undoing the only exchange returns a no retry target notice" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-then-retry-empty")
    {:ok, caller} = create_human("ai-agent-target-undo-then-retry-empty-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("answer to undo")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-undo-retry-empty-1",
        "hello",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, old_outbound}
    old_external_id = "external:" <> old_outbound["id"]

    undo_entry =
      command_entry(invocation.mailbox_session_id, "evt-undo-retry-empty-2", "/undo", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
                    %{"op" => "recall", "target_external_id" => ^old_external_id}}

    retry_entry =
      command_entry(
        invocation.mailbox_session_id,
        "evt-undo-retry-empty-3",
        "/retry",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, retry_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, feedback_outbound}

    assert [
             %{
               "kind" => "control_notice",
               "body" => %{
                 "text" => "There is no previous assistant reply to retry.",
                 "short_text" => "No Retry"
               }
             }
           ] = feedback_outbound["content"]

    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}, 50
    refute_received {:failed, _reason}
  end

  test "undo sends control notice when there is no recallable assistant message" do
    {:ok, agent} = create_ai_agent("ai-agent-target-undo-no-recall")
    {:ok, caller} = create_human("ai-agent-target-undo-no-recall-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("answer without delivery metadata")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-undo-no-recall-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _old_outbound}

    assistant = Repo.one!(from m in Message, where: m.role == :assistant)
    {:ok, _message} = Conversations.update_message(assistant, %{metadata: %{}})

    undo_entry =
      command_entry(invocation.mailbox_session_id, "evt-undo-no-recall-2", "/undo", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, undo_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, feedback_outbound}

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
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("initial answer")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-stop-recall-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _initial_outbound}

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
          "generation" => %{"lease_id" => lease_id, "trigger_message_id" => user.id},
          "delivery" => delivery_metadata("om_streaming"),
          "stream" => %{"stream_id" => "stream_stop_recall", "status" => "open"}
        }
      })

    stop_entry =
      command_entry(invocation.mailbox_session_id, "evt-stop-recall-2", "/stop", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, stop_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
                    %{"op" => "recall", "target_external_id" => "om_streaming"}}

    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _feedback_outbound},
                   50
  end

  test "latest addressed edit to ignored text aborts active generation without republish" do
    {:ok, agent} = create_ai_agent("ai-agent-target-edit-abort")
    {:ok, caller} = create_human("ai-agent-target-edit-abort-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("initial answer")

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-edit-abort-1", "@agent please handle this", caller.uid)
      |> with_provider_message_id("provider-edit-abort-1")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _initial_outbound}

    conversation = Repo.one!(Conversation)
    user = Repo.one!(from message in Message, where: message.role == :user)
    {:ok, leased, lease_id} = acquire_test_generation(conversation, user.id)

    {:ok, _conversation, generating} =
      Conversations.append_message(leased, %{
        conversation_id: leased.id,
        role: :assistant,
        kind: :normal,
        status: :generating,
        content: [],
        metadata: %{
          "generation" => %{"lease_id" => lease_id, "trigger_message_id" => user.id},
          "delivery" => delivery_metadata("om_edit_abort_streaming"),
          "stream" => %{"stream_id" => "stream_edit_abort", "status" => "open"}
        }
      })

    edit_entry =
      invocation.mailbox_session_id
      |> edit_entry("evt-edit-abort-2", "不用管了", caller.uid)
      |> with_provider_message_id("provider-edit-abort-1")
      |> with_routing_facts(%{
        "attention_reason" => "unaddressed",
        "group_message_mode" => "addressed_only"
      })

    assert :ok = BullX.AIAgent.handle_event(invocation, edit_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
                    %{"op" => "recall", "target_external_id" => "om_edit_abort_streaming"}}

    assert Repo.get!(Conversation, conversation.id).generation["cancellation_reason"] ==
             "source_message_edited"

    assert get_in(Repo.get!(Message, user.id).metadata, ["transcript_effect", "state"]) ==
             "superseded"

    assert %Message{
             kind: :error,
             status: :complete,
             content: [
               %{
                 "type" => "error",
                 "code" => "generation_interrupted",
                 "retryable" => true
               }
             ]
           } = interrupted = Repo.get!(Message, generating.id)

    assert get_in(interrupted.metadata, ["transcript_effect", "state"]) == "interrupted"
    assert get_in(interrupted.metadata, ["stream", "status"]) == "interrupted"
    refute Repo.exists?(from entry in Entry, where: entry.status == :pending)
  end

  test "stop sends control notice when unfinished output is not recallable" do
    {:ok, agent} = create_ai_agent("ai-agent-target-stop-no-recall")
    {:ok, caller} = create_human("ai-agent-target-stop-no-recall-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("initial answer")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-stop-no-recall-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _initial_outbound}

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
          "generation" => %{"lease_id" => lease_id, "trigger_message_id" => user.id},
          "stream" => %{"stream_id" => "stream_stop_no_recall", "status" => "open"}
        }
      })

    stop_entry =
      command_entry(invocation.mailbox_session_id, "evt-stop-no-recall-2", "/stop", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, stop_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, feedback_outbound}

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
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("initial answer")

    invocation = invocation(agent.uid)

    entry =
      addressed_entry(invocation.mailbox_session_id, "evt-steer-feedback-1", "hello", caller.uid)

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _initial_outbound}

    conversation = Repo.one!(Conversation)

    {:ok, _leased, _lease_id} =
      Conversations.acquire_generation_lease(
        conversation,
        %{
          "owner_trigger_type" => "test",
          "owner_trigger_id" => "steer-feedback",
          "trigger_message_id" => Repo.one!(from m in Message, where: m.role == :user).id,
          "generation_lease_ttl_ms" => 60_000,
          "generation_heartbeat_interval_ms" => 5_000,
          "generation_max_runtime_ms" => 60_000
        },
        DateTime.utc_now(:microsecond)
      )

    steer_entry =
      command_entry(
        invocation.mailbox_session_id,
        "evt-steer-feedback-2",
        "/steer focus on the latest constraint",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, steer_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, steer_outbound}

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
        "main_llm" => %{
          "provider_id" => "openai_proxy",
          "model" => "gpt-test",
          "context_window" => 16_000
        },
        "instructions" => "Answer briefly."
      })

    {:ok, caller} = create_human("ai-agent-target-compress-feedback-caller")
    grant(caller.uid, agent.uid, "invoke")

    invocation = invocation(agent.uid)

    long_text = String.duplicate("compressible context ", 900)

    BullX.AIAgent.FakeLLMClient.push_response("first answer")

    first_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-compress-feedback-1",
        long_text,
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _first_outbound}

    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    second_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-compress-feedback-2",
        long_text,
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _second_outbound}

    BullX.AIAgent.FakeLLMClient.push_response("compressed summary")

    compress_entry =
      command_entry(
        invocation.mailbox_session_id,
        "evt-compress-feedback-3",
        "/compress",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, compress_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
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

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
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

  test "provider context overflow triggers compression and retries generation" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-overflow-retry", %{
        "main_llm" => %{
          "provider_id" => "openai_proxy",
          "model" => "gpt-test",
          "context_window" => 16_000
        },
        "instructions" => "Answer briefly.",
        "context" => %{"max_turns" => 5, "compression_threshold_ratio" => 0.95}
      })

    {:ok, caller} = create_human("ai-agent-target-overflow-retry-caller")
    grant(caller.uid, agent.uid, "invoke")

    invocation = invocation(agent.uid)
    long_text = String.duplicate("compressible context ", 900)

    BullX.AIAgent.FakeLLMClient.push_response("first answer")

    first_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-overflow-retry-1",
        long_text,
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _first_outbound}

    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    second_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-overflow-retry-2",
        long_text,
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _second_outbound}

    BullX.AIAgent.FakeLLMClient.push_error(
      ReqLLM.Error.API.Request.exception(
        reason: "context length exceeded",
        status: 400,
        response_body: %{
          "error" => %{
            "code" => "context_length_exceeded",
            "message" => "input token count exceeds the maximum number of input tokens"
          }
        }
      )
    )

    BullX.AIAgent.FakeLLMClient.push_response("compressed after overflow")
    BullX.AIAgent.FakeLLMClient.push_response("answer after compression")

    third_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-overflow-retry-3",
        "third context",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, third_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, third_outbound}

    assert [
             %{
               "kind" => "text",
               "body" => %{"text" => "answer after compression"}
             }
           ] = third_outbound["content"]

    assert [] = Repo.all(from m in Message, where: m.kind == :error)

    assert %Message{
             kind: :summary,
             metadata: %{"trigger" => "provider_context_overflow"}
           } = Repo.one!(from m in Message, where: m.kind == :summary)

    assert %Message{
             role: :assistant,
             kind: :normal,
             content: [%{"text" => "answer after compression"}]
           } =
             Repo.one!(
               from m in Message,
                 where: m.role == :assistant and m.kind == :normal,
                 order_by: [desc: m.inserted_at],
                 limit: 1
             )
  end

  test "compress no-op updates progress notice without duplicate control notice" do
    {:ok, agent} =
      create_ai_agent("ai-agent-target-compress-noop-feedback", %{
        "instructions" => "Answer briefly."
      })

    {:ok, caller} = create_human("ai-agent-target-compress-noop-feedback-caller")
    grant(caller.uid, agent.uid, "invoke")

    invocation = invocation(agent.uid)

    BullX.AIAgent.FakeLLMClient.push_response("short answer")

    first_entry =
      addressed_entry(
        invocation.mailbox_session_id,
        "evt-compress-noop-feedback-1",
        "short message",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _first_outbound}

    compress_entry =
      command_entry(
        invocation.mailbox_session_id,
        "evt-compress-noop-feedback-2",
        "/compress",
        caller.uid
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, compress_entry)
    assert_received :closed

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
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

    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address,
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

    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}, 50
    assert [] = Repo.all(from m in Message, where: m.kind == :summary)
  end

  test "ambient observe-only events are recorded but do not invoke generation" do
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient")

    BullX.AIAgent.FakeLLMClient.push_response("should not be consumed")

    invocation = invocation(agent.uid)
    entry = ambient_entry(invocation.mailbox_session_id, "evt-ambient-1", "background note")

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

  test "ambient group observe_all mode records context without intervention" do
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient-observe-all")

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> ambient_entry("evt-ambient-observe-all", "background note")
      |> put_in([:cloud_event, "data", "routing_facts", "group_message_mode"], "observe_all")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    batch_key = "#{agent.uid}:#{conversation.id}"

    assert {:error, :missing} = AmbientBatch.take(batch_key)
    AmbientBatch.cleanup(batch_key)
  end

  test "ambient group engage_all mode can intervene" do
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient-engage-all")

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> ambient_entry("evt-ambient-engage-all", "background note")
      |> put_in([:cloud_event, "data", "routing_facts", "group_message_mode"], "engage_all")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    batch_key = "#{agent.uid}:#{conversation.id}"

    assert {:ok, %{"ambient_mode" => "may_intervene"}, _items} = AmbientBatch.take(batch_key)
    AmbientBatch.cleanup(batch_key)
  end

  test "long ambient messages store a brief on the same ambient message" do
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient-brief")

    BullX.AIAgent.FakeLLMClient.push_response("short safe brief")

    invocation = invocation(agent.uid)
    long_text = String.duplicate("background context ", 80)
    entry = ambient_entry(invocation.mailbox_session_id, "evt-ambient-brief-1", long_text)

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
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient-no-reply-anchor")

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> ambient_entry("evt-ambient-no-reply-anchor", "background note")
      |> put_in([:cloud_event, "data", "reply_address"], %{
        "adapter" => "im_gateway_test",
        "channel_id" => "default",
        "scope_id" => "scene-1",
        "scope_kind" => "group",
        "reply_to_external_id" => "provider-message-1"
      })
      |> put_in([:cloud_event, "data", "routing_facts", "group_message_mode"], "engage_all")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    batch_key = "#{agent.uid}:#{conversation.id}"

    assert {:ok, meta, _items} = AmbientBatch.take(batch_key)
    refute Map.has_key?(meta["reply_address"], "reply_to_external_id")
    assert meta["reply_address"]["scope_id"] == "scene-1"

    AmbientBatch.cleanup(batch_key)
  end

  test "ambient intervention batches use a short window when text names the agent" do
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient-agent-name")

    invocation = invocation(agent.uid)

    entry =
      invocation.mailbox_session_id
      |> ambient_entry("evt-ambient-agent-name", "#{agent.uid} 看一下")
      |> put_in([:cloud_event, "data", "routing_facts", "group_message_mode"], "engage_all")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}

    conversation = Repo.one!(Conversation)
    batch_key = "#{agent.uid}:#{conversation.id}"

    assert {:ok, meta, _items} = AmbientBatch.take(batch_key)
    assert meta["due_at"] - System.system_time(:millisecond) <= 5_000

    AmbientBatch.cleanup(batch_key)
  end

  test "ambient intervention shortens an open batch after the agent has answered" do
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient-after-answer")

    invocation = invocation(agent.uid)

    first_entry =
      invocation.mailbox_session_id
      |> ambient_entry("evt-ambient-after-answer-1", "first")
      |> put_in([:cloud_event, "data", "routing_facts", "group_message_mode"], "engage_all")

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
      invocation.mailbox_session_id
      |> ambient_entry("evt-ambient-after-answer-2", "follow up")
      |> put_in([:cloud_event, "data", "routing_facts", "group_message_mode"], "engage_all")

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    refute_received {:failed, _reason}

    batch_key = "#{agent.uid}:#{conversation.id}"

    assert {:ok, meta, items} = AmbientBatch.take(batch_key)
    assert meta["due_at"] - System.system_time(:millisecond) <= 5_000
    assert Enum.map(items, & &1["text"]) == ["first", "follow up"]

    AmbientBatch.cleanup(batch_key)
  end

  test "provider ref source ids ignore reply address targets" do
    event_data = %{
      "refs" => [%{"kind" => "im_gateway_test.message", "id" => "source-message-1"}],
      "raw_ref" => %{
        "kind" => "im_gateway_test.event",
        "id" => "revision-event-1",
        "message_id" => "source-message-1"
      },
      "reply_address" => %{
        "reply_to_external_id" => "reply-target-1",
        "message_id" => "reply-address-message-1",
        "external_id" => "reply-address-external-1"
      }
    }

    assert Event.source_message_ids(event_data) == ["source-message-1"]

    assert Event.provider_ref_metadata(event_data) == %{
             "provider_refs" => %{"message_ids" => ["source-message-1"]}
           }
  end

  test "historical addressed edit records a ref introspection without rewriting old content" do
    {:ok, agent} = create_ai_agent("ai-agent-target-edit-history")
    {:ok, caller} = create_human("ai-agent-target-edit-history-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("first answer")
    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    invocation = invocation(agent.uid)

    first_entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-edit-history-1", "first", caller.uid)
      |> with_provider_message_id("provider-edit-history-1")

    second_entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-edit-history-2", "second", caller.uid)
      |> with_provider_message_id("provider-edit-history-2")

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    edit_entry =
      invocation.mailbox_session_id
      |> edit_entry("evt-edit-history-3", "first edited", caller.uid)
      |> with_provider_message_id("provider-edit-history-1")

    assert :ok = BullX.AIAgent.handle_event(invocation, edit_entry)
    assert_received :closed
    refute_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}
    refute_received {:failed, _reason}

    first_message = Repo.get_by!(Message, event_id: "evt-edit-history-1")
    assert [%{"text" => "first"}, %{"text" => marker}] = first_message.content
    assert marker =~ "ref id:"

    introspection = Repo.get_by!(Message, role: :user, kind: :introspection)
    assert get_in(List.first(introspection.content), ["text"]) =~ "被编辑为：first edited"
  end

  test "lifecycle edit can revise a target after weak mailbox session id drift" do
    {:ok, agent} = create_ai_agent("ai-agent-target-edit-session-drift")
    {:ok, caller} = create_human("ai-agent-target-edit-session-drift-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")

    original_invocation = invocation(agent.uid)

    original_entry =
      original_invocation.mailbox_session_id
      |> addressed_entry("evt-edit-session-drift-1", "@agent original", caller.uid)
      |> with_provider_message_id("provider-edit-session-drift-1")

    assert :ok = BullX.AIAgent.handle_event(original_invocation, original_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    drifted_invocation = %{
      original_invocation
      | mailbox_session_id: BullX.Ext.gen_uuid_v7()
    }

    edit_entry =
      drifted_invocation.mailbox_session_id
      |> edit_entry("evt-edit-session-drift-2", "@agent revised", caller.uid)
      |> with_provider_message_id("provider-edit-session-drift-1")
      |> with_routing_facts(%{"attention_reason" => "mention"})

    assert :ok = BullX.AIAgent.handle_event(drifted_invocation, edit_entry)
    assert_received :closed

    original_message = Repo.get_by!(Message, event_id: "evt-edit-session-drift-1")
    assert get_in(original_message.metadata, ["transcript_effect", "state"]) == "superseded"

    republished_entry =
      Entry
      |> where([entry], entry.status == :pending)
      |> Repo.one!()

    assert republished_entry.attention == :addressed

    assert get_in(republished_entry.cloud_event, ["data", "content"]) == [
             %{"type" => "text", "text" => "@agent revised"}
           ]
  end

  test "historical addressed delete records a ref introspection without deleting old content" do
    {:ok, agent} = create_ai_agent("ai-agent-target-delete-history")
    {:ok, caller} = create_human("ai-agent-target-delete-history-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("first answer")
    BullX.AIAgent.FakeLLMClient.push_response("second answer")

    invocation = invocation(agent.uid)

    first_entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-delete-history-1", "first", caller.uid)
      |> with_provider_message_id("provider-delete-history-1")

    second_entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-delete-history-2", "second", caller.uid)
      |> with_provider_message_id("provider-delete-history-2")

    assert :ok = BullX.AIAgent.handle_event(invocation, first_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    assert :ok = BullX.AIAgent.handle_event(invocation, second_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    delete_entry =
      invocation.mailbox_session_id
      |> delete_entry("evt-delete-history-3", caller.uid)
      |> with_provider_message_id("provider-delete-history-1")

    assert :ok = BullX.AIAgent.handle_event(invocation, delete_entry)
    assert_received :closed
    refute_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}
    refute_received {:failed, _reason}

    first_message = Repo.get_by!(Message, event_id: "evt-delete-history-1")
    assert [%{"text" => "first"}, %{"text" => marker}] = first_message.content
    assert marker =~ "ref id:"

    introspection = Repo.get_by!(Message, role: :user, kind: :introspection)
    assert get_in(List.first(introspection.content), ["text"]) =~ "已被删除"
  end

  test "latest addressed batch edit republishes the full revised batch" do
    {:ok, agent} = create_ai_agent("ai-agent-target-batch-edit")
    {:ok, caller} = create_human("ai-agent-target-batch-edit-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")
    BullX.AIAgent.FakeLLMClient.push_response("new answer")

    invocation = invocation(agent.uid)

    batch_entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-batch-edit-1", "@agent first\nsecond", caller.uid)
      |> with_im_batch(
        [
          {"provider-batch-edit-1", "@agent first", "addressed"},
          {"provider-batch-edit-2", "second", "ambient"}
        ],
        "addressed"
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, batch_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    edit_entry =
      invocation.mailbox_session_id
      |> edit_entry("evt-batch-edit-2", "second edited", caller.uid)
      |> with_provider_message_id("provider-batch-edit-2")
      |> with_routing_facts(%{
        "attention_reason" => "unaddressed",
        "group_message_mode" => "engage_all"
      })

    assert :ok = BullX.AIAgent.handle_event(invocation, edit_entry)
    assert_received :closed

    old_user = Repo.get_by!(Message, event_id: "evt-batch-edit-1", role: :user)
    assert get_in(old_user.metadata, ["transcript_effect", "state"]) == "superseded"

    republished_entry =
      Entry
      |> where([entry], entry.status == :pending)
      |> Repo.one!()

    assert republished_entry.attention == :addressed

    assert get_in(republished_entry.cloud_event, ["data", "content"]) == [
             %{"type" => "text", "text" => "@agent first\nsecond edited"}
           ]

    assert get_in(republished_entry.cloud_event, ["data", "im_batch", "effective_attention"]) ==
             "addressed"

    force_mailbox_entries_ready()
    assert {:ok, 1} = BullX.MailBox.process_ready(1)
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    assert %Message{
             role: :user,
             kind: :normal,
             content: [%{"type" => "text", "text" => "@agent first\nsecond edited"}],
             metadata: %{"im_batch" => %{"effective_attention" => "addressed"}}
           } =
             Message
             |> where([message], message.role == :user)
             |> where([message], is_nil(fragment("?->'transcript_effect'", message.metadata)))
             |> order_by([message], desc: message.inserted_at)
             |> Repo.one!()
  end

  test "latest addressed batch edit can downgrade to ambient when the source engages all" do
    {:ok, agent} = create_ai_agent("ai-agent-target-batch-downgrade-ambient")
    {:ok, caller} = create_human("ai-agent-target-batch-downgrade-ambient-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")

    invocation = invocation(agent.uid)

    batch_entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-batch-downgrade-1", "@agent first\nsecond", caller.uid)
      |> with_im_batch(
        [
          {"provider-batch-downgrade-1", "@agent first", "addressed"},
          {"provider-batch-downgrade-2", "second", "ambient"}
        ],
        "addressed"
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, batch_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    edit_entry =
      invocation.mailbox_session_id
      |> edit_entry("evt-batch-downgrade-2", "first", caller.uid)
      |> with_provider_message_id("provider-batch-downgrade-1")
      |> with_routing_facts(%{
        "attention_reason" => "unaddressed",
        "group_message_mode" => "engage_all"
      })

    assert :ok = BullX.AIAgent.handle_event(invocation, edit_entry)
    assert_received :closed
    drain_deliveries()

    old_user = Repo.get_by!(Message, event_id: "evt-batch-downgrade-1", role: :user)
    assert get_in(old_user.metadata, ["transcript_effect", "state"]) == "superseded"

    republished_entry =
      Entry
      |> where([entry], entry.status == :pending)
      |> Repo.one!()

    assert republished_entry.attention == :ambient

    assert get_in(republished_entry.cloud_event, ["data", "content"]) == [
             %{"type" => "text", "text" => "first\nsecond"}
           ]

    assert get_in(republished_entry.cloud_event, ["data", "im_batch", "effective_attention"]) ==
             "ambient"

    force_mailbox_entries_ready()
    assert {:ok, 1} = BullX.MailBox.process_ready(1)
    refute_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}, 50

    assert %Message{
             role: :im_ambient,
             kind: :normal,
             content: [%{"type" => "text", "text" => "first\nsecond"}],
             metadata: %{"im_batch" => %{"effective_attention" => "ambient"}}
           } =
             Message
             |> where([message], message.role == :im_ambient)
             |> where([message], is_nil(fragment("?->'transcript_effect'", message.metadata)))
             |> Repo.one!()
  end

  test "latest addressed batch edit to unaddressed addressed-only content does not republish" do
    {:ok, agent} = create_ai_agent("ai-agent-target-batch-downgrade-ignored")
    {:ok, caller} = create_human("ai-agent-target-batch-downgrade-ignored-caller")
    grant(caller.uid, agent.uid, "invoke")
    BullX.AIAgent.FakeLLMClient.push_response("old answer")

    invocation = invocation(agent.uid)

    batch_entry =
      invocation.mailbox_session_id
      |> addressed_entry("evt-batch-ignored-1", "@agent first", caller.uid)
      |> with_im_batch(
        [
          {"provider-batch-ignored-1", "@agent first", "addressed"}
        ],
        "addressed"
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, batch_entry)
    assert_received :closed
    assert_receive {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    edit_entry =
      invocation.mailbox_session_id
      |> edit_entry("evt-batch-ignored-2", "first", caller.uid)
      |> with_provider_message_id("provider-batch-ignored-1")
      |> with_routing_facts(%{
        "attention_reason" => "unaddressed",
        "group_message_mode" => "addressed_only"
      })

    assert :ok = BullX.AIAgent.handle_event(invocation, edit_entry)
    assert_received :closed
    drain_deliveries()

    old_user = Repo.get_by!(Message, event_id: "evt-batch-ignored-1", role: :user)
    assert get_in(old_user.metadata, ["transcript_effect", "state"]) == "superseded"

    refute Repo.exists?(from entry in Entry, where: entry.status == :pending)

    refute Repo.exists?(
             from message in Message,
               where: message.role in [:user, :im_ambient],
               where: is_nil(fragment("?->'transcript_effect'", message.metadata))
           )
  end

  test "ambient batch edit rewrites only the matching item" do
    {:ok, agent} = create_ai_agent("ai-agent-target-ambient-batch-edit")
    {:ok, caller} = create_human("ai-agent-target-ambient-batch-edit-caller")
    invocation = invocation(agent.uid)

    batch_entry =
      invocation.mailbox_session_id
      |> ambient_entry("evt-ambient-batch-edit-1", "first\nsecond")
      |> put_in([:routing_context], routing_context(caller.uid))
      |> with_im_batch(
        [
          {"provider-ambient-batch-edit-1", "first", "ambient"},
          {"provider-ambient-batch-edit-2", "second", "ambient"}
        ],
        "ambient"
      )

    assert :ok = BullX.AIAgent.handle_event(invocation, batch_entry)
    assert_received :closed

    edit_entry =
      invocation.mailbox_session_id
      |> edit_entry("evt-ambient-batch-edit-2", "second edited", caller.uid)
      |> with_provider_message_id("provider-ambient-batch-edit-2")
      |> with_routing_facts(%{
        "attention_reason" => "unaddressed",
        "group_message_mode" => "engage_all"
      })

    assert :ok = BullX.AIAgent.handle_event(invocation, edit_entry)
    assert_received :closed
    refute_received {:im_gateway_adapter_delivered, _source, _reply_address, _outbound}

    assert %Message{
             role: :im_ambient,
             kind: :normal,
             content: [%{"type" => "text", "text" => "first\nsecond edited"}],
             metadata: %{
               "im_batch" => %{
                 "effective_attention" => "ambient",
                 "items" => [first, second]
               }
             }
           } = Repo.get_by!(Message, event_id: "evt-ambient-batch-edit-1")

    assert first["text"] == "first"
    assert second["text"] == "second edited"
  end

  test "unsupported events close the invocation without creating business records" do
    {:ok, agent} = create_ai_agent("ai-agent-target-unsupported")
    invocation = invocation(agent.uid)
    entry = unsupported_entry(invocation.mailbox_session_id, "evt-unsupported-1")

    assert :ok = BullX.AIAgent.handle_event(invocation, entry)
    assert_received :closed
    refute_received {:failed, _reason}
    assert [] = Repo.all(Conversation)
    assert [] = Repo.all(Message)
  end

  defp acquire_test_generation(conversation, trigger_message_id) do
    Conversations.acquire_generation_lease(
      conversation,
      %{
        "owner_trigger_type" => "test",
        "owner_trigger_id" => "stop-test",
        "trigger_message_id" => trigger_message_id,
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
          "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
          "mission" => "Handle AIAgent target tests.",
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

  defp grant(caller_principal_uid, agent_uid, action) do
    AuthZ.create_permission_grant(%{
      principal_uid: caller_principal_uid,
      resource_pattern: ACL.resource(agent_uid),
      action: action
    })
  end

  defp invocation(agent_uid) do
    %{
      mailbox_session_id: BullX.Ext.gen_uuid_v7(),
      event_routing_rule_id: BullX.Ext.gen_uuid_v7(),
      target_type: :ai_agent,
      target_ref: agent_uid,
      scope_key: "scope",
      output: BullX.MailBox.StreamingOutput,
      close: fn -> send(self(), :closed) end,
      fail: fn reason -> send(self(), {:failed, reason}) end
    }
  end

  defp addressed_entry(mailbox_session_id, event_id, text, caller_principal_uid) do
    entry(
      mailbox_session_id,
      event_id,
      "bullx.message.received",
      text,
      caller_principal_uid,
      :addressed
    )
  end

  defp command_entry(mailbox_session_id, event_id, text, caller_principal_uid) do
    {command_name, args} = command_parts(text)
    args_kind = command_args_kind(args)

    mailbox_session_id
    |> entry(
      event_id,
      "bullx.command.invoked",
      command_content(command_name, args),
      caller_principal_uid,
      :command
    )
    |> put_in([:cloud_event, "data", "command"], %{
      "name" => command_name,
      "args_text" => args,
      "args_kind" => args_kind,
      "surface" => "slash_text"
    })
    |> put_in([:cloud_event, "data", "routing_facts"], %{
      "command_name" => command_name,
      "command_surface" => "slash_text",
      "command_args_kind" => args_kind
    })
  end

  defp command_parts(text) do
    text
    |> String.trim_leading()
    |> String.trim_leading("/")
    |> String.split(~r/\s+/, parts: 2)
    |> case do
      [name, args] -> {String.downcase(name), String.trim(args)}
      [name] -> {String.downcase(name), ""}
    end
  end

  defp command_args_kind(""), do: "none"
  defp command_args_kind(_args), do: "text"

  defp command_content(command_name, ""), do: "/" <> command_name
  defp command_content(_command_name, args), do: args

  defp ambient_entry(mailbox_session_id, event_id, text) do
    entry(mailbox_session_id, event_id, "bullx.message.received", text, nil, :ambient)
  end

  defp edit_entry(mailbox_session_id, event_id, text, caller_principal_uid) do
    entry(
      mailbox_session_id,
      event_id,
      "bullx.message.edited",
      text,
      caller_principal_uid,
      :addressed
    )
  end

  defp delete_entry(mailbox_session_id, event_id, caller_principal_uid) do
    entry(
      mailbox_session_id,
      event_id,
      "bullx.message.deleted",
      "[message deleted]",
      caller_principal_uid,
      :addressed
    )
  end

  defp unsupported_entry(mailbox_session_id, event_id) do
    entry(mailbox_session_id, event_id, "example.unsupported", "ignored", nil, :system)
  end

  defp force_mailbox_entries_ready do
    Repo.update_all(Entry, set: [available_at: DateTime.utc_now(:microsecond)])
  end

  defp drain_deliveries do
    receive do
      {:im_gateway_adapter_delivered, _source, _reply_address, _outbound} ->
        drain_deliveries()
    after
      25 -> :ok
    end
  end

  defp with_provider_message_id(entry, provider_message_id) do
    entry
    |> put_in([:cloud_event, "data", "refs"], [
      %{"kind" => "im_gateway_test.message", "id" => provider_message_id}
    ])
    |> put_in([:cloud_event, "data", "raw_ref"], %{
      "kind" => "im_gateway_test.message",
      "id" => provider_message_id,
      "message_id" => provider_message_id
    })
    |> put_in(
      [:cloud_event, "data", "reply_address", "reply_to_external_id"],
      provider_message_id
    )
  end

  defp with_routing_facts(entry, facts) do
    update_in(entry, [:cloud_event, "data", "routing_facts"], fn current ->
      Map.merge(current || %{}, facts)
    end)
  end

  defp with_im_batch(entry, items, effective_attention) do
    batch_items = Enum.map(items, &batch_item/1)
    refs = Enum.flat_map(batch_items, &(&1["refs"] || []))

    entry
    |> put_in([:cloud_event, "data", "content"], [
      %{"type" => "text", "text" => batch_text(batch_items)}
    ])
    |> put_in([:cloud_event, "data", "refs"], refs)
    |> put_in([:cloud_event, "data", "im_batch"], %{
      "effective_attention" => effective_attention,
      "items" => batch_items
    })
    |> with_routing_facts(%{
      "attention_reason" => batch_attention_reason(effective_attention),
      "batch_effective_attention" => effective_attention,
      "group_message_mode" => "engage_all"
    })
  end

  defp batch_item({provider_message_id, text, attention}) do
    %{
      "provider_message_ids" => [provider_message_id],
      "text" => text,
      "content" => [%{"type" => "text", "text" => text}],
      "attention" => attention,
      "state" => "active",
      "refs" => [%{"kind" => "im_gateway_test.message", "id" => provider_message_id}],
      "raw_ref" => %{
        "kind" => "im_gateway_test.message",
        "id" => provider_message_id,
        "message_id" => provider_message_id
      },
      "routing_facts" => %{
        "attention_reason" => batch_attention_reason(attention),
        "group_message_mode" => "engage_all"
      }
    }
  end

  defp batch_text(items) do
    items
    |> Enum.map(& &1["text"])
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp batch_attention_reason("addressed"), do: "batch_addressed"
  defp batch_attention_reason(_attention), do: "unaddressed"

  defp entry(mailbox_session_id, event_id, event_type, text, caller_principal_uid, attention) do
    %{
      id: BullX.Ext.gen_uuid_v7(),
      entry_seq: 1,
      mailbox_session_id: mailbox_session_id,
      attention: attention,
      event_source: "/feishu",
      event_id: event_id,
      cloud_event: %{
        "id" => event_id,
        "source" => "/feishu",
        "type" => event_type,
        "data" => %{
          "content" => [%{"type" => "text", "text" => text}],
          "channel" => %{
            "adapter" => "im_gateway_test",
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
          "reply_address" => %{"adapter" => "im_gateway_test", "channel_id" => "default"},
          "routing_facts" => %{},
          "raw_ref" => nil
        }
      },
      routing_context: routing_context(caller_principal_uid),
      appended_at: DateTime.utc_now(:microsecond)
    }
  end

  defp routing_context(nil), do: %{}
  defp routing_context(principal_uid), do: %{"triggering_principal_uid" => principal_uid}

  defp allow_catalog_cache do
    case GenServer.whereis(BullX.LLM.Catalog.Cache) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), pid)
      nil -> :ok
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
