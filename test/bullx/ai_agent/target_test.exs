defmodule BullX.AIAgent.TargetTest do
  use BullX.DataCase, async: false

  alias BullX.AIAgent.{ACL, Conversation, Message}
  alias BullX.AuthZ
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
    assert get_in(outbound, ["content", Access.at(0), "body", "text"]) == "Command denied."
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
