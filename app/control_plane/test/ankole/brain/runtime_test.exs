defmodule Ankole.Brain.RuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.RPCBroker
  alias Ankole.Brain.RuntimeContext
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Snapshot
  alias Ankole.Brain.Sources
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.Entry, as: SignalEntry
  alias Ankole.SignalsGateway.Ingress
  alias Ankole.SubagentDelegations.Schemas.Delegation

  test "conversation snapshot auto-creates the pinned memo and remains frozen" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, "brain-snapshot-root",
        metadata: %{"brain" => %{"visibility" => "public"}}
      )

    assert {:ok, first} = Snapshot.get_or_create(conversation)
    assert first["channel_entry"] == nil
    assert first["pinned_memo"] == %{"resident_text" => "", "truncated" => false}

    {:ok, scope} = Scope.for_store(agent.uid, "public")

    pinned =
      Repo.get_by!(Entry,
        owner_uid: agent.uid,
        store_key: "public",
        type: "agent_system_pinned_memo"
      )

    assert {:ok, %{entry: opened_pinned}} = Knowledge.open(scope, pinned.id, block_limit: :all)
    assert opened_pinned.id == pinned.id

    assert {:ok, [bootstrap_audit]} =
             Knowledge.list_audit(scope,
               action: "create_entry",
               entry_id: pinned.id,
               limit: 1
             )

    assert bootstrap_audit.actor_kind == nil
    assert bootstrap_audit.actor_uid == nil
    assert bootstrap_audit.metadata["surface"] == "conversation_snapshot"
    assert bootstrap_audit.metadata["automatic"]

    assert {:ok, _result} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: pinned.id,
                 expected_entry_lock_version: pinned.lock_version,
                 body: "Remember the durable preference"
               },
               %{kind: :agent, uid: agent.uid}
             )

    # The stale caller struct does not bypass the transaction's second check.
    assert {:ok, ^first} = Snapshot.get_or_create(conversation)
    refute first["pinned_memo"]["resident_text"] =~ "durable preference"

    {:ok, successor} =
      Conversations.ensure_conversation(agent.uid, "brain-snapshot-successor",
        metadata: %{"brain" => %{"visibility" => "public"}}
      )

    assert {:ok, refreshed} = Snapshot.get_or_create(successor)
    assert refreshed["pinned_memo"]["resident_text"] == "Remember the durable preference"
  end

  test "group snapshot uses channel_id identity and subagents inherit the parent conversation" do
    %{principal: agent} = agent_fixture()
    channel_id = "lark:group:brain-snapshot"
    {:ok, public_scope} = Scope.for_store(agent.uid, "public")

    assert {:ok, %{results: [%{entry_id: entry_id, entry_lock_version: 1}]}} =
             Knowledge.apply_operations(
               public_scope,
               %{
                 operation: "create_entry",
                 name: "Old Channel Display Name",
                 type: "channel",
                 summary: "",
                 properties: %{"channel_id" => channel_id}
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, _result} =
             Knowledge.apply_operations(
               public_scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: "Channel decisions require an explicit owner"
               },
               %{kind: :agent, uid: agent.uid}
             )

    parent_session = "brain-parent-session"

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, parent_session,
        metadata: %{
          "brain" => %{
            "visibility" => "public",
            "channel_id" => channel_id,
            "channel_kind" => "im_group"
          }
        }
      )

    assert {:ok, parent_snapshot} = Snapshot.get_or_create(conversation)

    assert parent_snapshot["channel_entry"] == %{
             "resident_text" => "Channel decisions require an explicit owner",
             "truncated" => false
           }

    delegation =
      %Delegation{}
      |> Delegation.creation_changeset(%{
        agent_uid: agent.uid,
        session_id: parent_session,
        tool_call_id: "brain-subagent-tool-call",
        title: "Brain inheritance",
        task: "Verify inherited Brain snapshot",
        workdir: "/workspace",
        runtime: "task_worker",
        codex_account_id: "aigateway",
        reply_route: %{"signal_channel_id" => channel_id},
        attempts: 1,
        status: "running",
        result: %{},
        error: %{},
        metadata: %{"brain_parent_conversation_id" => conversation.id}
      })
      |> Repo.insert!()

    conversation
    |> Ecto.Changeset.change(ended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    {:ok, replacement} =
      Conversations.ensure_conversation(agent.uid, parent_session,
        metadata: %{
          "brain" => %{
            "visibility" => "public",
            "channel_id" => channel_id,
            "channel_kind" => "im_group"
          }
        }
      )

    refute replacement.id == conversation.id

    subagent_turn = turn_ref(agent.uid, "subagent:#{delegation.id}")

    assert {:ok, %{conversation: inherited, scope: inherited_scope}} =
             RuntimeContext.resolve(subagent_turn)

    assert inherited.id == conversation.id
    assert inherited_scope.writable_store_key == "public"
    assert {:ok, ^parent_snapshot} = Snapshot.get_or_create(inherited)
    assert AIGatewayLink.visible_signal_document_ids(subagent_turn) == []
  end

  test "RPC derives owner store and author, and opens stable block pages" do
    %{principal: agent} = agent_fixture()
    %{principal: other} = human_fixture()
    session_id = "brain-rpc-session"

    {:ok, _conversation} =
      Conversations.ensure_conversation(agent.uid, session_id,
        metadata: %{"brain" => %{"visibility" => "public"}}
      )

    turn = turn_ref(agent.uid, session_id)

    assert {:ok, create} =
             RPCBroker.handle_update(
               turn,
               %{
                 "request_id" => "brain-create",
                 "operation" => "create_entry",
                 "name" => "RPC Contract",
                 "type" => "fact",
                 "owner_uid" => other.uid,
                 "store_key" => "dm:#{other.uid}",
                 "author_kind" => "human",
                 "author_uid" => other.uid
               },
               "worker-route"
             )

    [created] = create["results"]
    entry_id = created["entry_id"]

    assert {:ok, first_append} =
             RPCBroker.handle_update(
               turn,
               %{
                 "operation" => "append_block",
                 "entry_id" => entry_id,
                 "expected_entry_lock_version" => 1,
                 "body" => "first page"
               },
               "worker-route"
             )

    assert {:ok, _second_append} =
             RPCBroker.handle_update(
               turn,
               %{
                 "operation" => "append_block",
                 "entry_id" => entry_id,
                 "expected_entry_lock_version" =>
                   first_append["results"] |> hd() |> Map.fetch!("entry_lock_version"),
                 "body" => "second page"
               },
               "worker-route"
             )

    assert {:ok, page_one} =
             RPCBroker.handle_open(
               turn,
               %{"entry_id" => entry_id, "block_limit" => 1},
               "worker-route"
             )

    assert page_one["entry"]["owner_uid"] == agent.uid
    assert page_one["entry"]["store_key"] == "public"

    assert [%{"body" => "first page", "author_kind" => "agent", "author_uid" => author}] =
             page_one["blocks"]

    assert author == agent.uid
    assert page_one["history_notice"] =~ "untrusted historical content"
    assert is_binary(page_one["next_block_cursor"])
    assert page_one["markdown"] =~ "first page"
    assert page_one["markdown"] =~ "作者：agent:#{agent.uid}"
    refute page_one["markdown"] =~ "second page"

    assert {:ok, page_two} =
             RPCBroker.handle_open(
               turn,
               %{
                 "entry_id" => entry_id,
                 "block_limit" => 1,
                 "block_cursor" => page_one["next_block_cursor"]
               },
               "worker-route"
             )

    assert [%{"body" => "second page"}] = page_two["blocks"]
    assert page_two["next_block_cursor"] == nil
  end

  test "source-learning RPC only admits blocks cited to its retained source" do
    %{principal: agent} = agent_fixture()
    session_id = "brain-source-learning-rpc"
    {:ok, scope} = Scope.for_store(agent.uid, "public")

    assert {:ok, source} =
             Sources.capture(
               scope,
               %{kind: "paste", title: "Source policy", content: "Keep supported claims."},
               agent.uid
             )

    {:ok, _conversation} =
      Conversations.ensure_conversation(agent.uid, session_id,
        metadata: %{"brain" => %{"visibility" => "public"}}
      )

    assert {:ok, actor_event} =
             SignalsGateway.append_actor_event(%{
               agent_uid: agent.uid,
               binding_name: "brain-console",
               session_id: session_id,
               source_event_id: "brain-source-learning-rpc",
               source_entry_id: source.document_id,
               type: "brain.source.learn",
               available_at: DateTime.utc_now(:microsecond),
               payload: %{
                 "data" => %{
                   "retained_source" => %{"document_id" => source.document_id}
                 }
               }
             })

    turn = turn_ref(agent.uid, session_id, actor_event.id)

    assert {:error, %{"code" => "source_learning_operation_not_allowed"}} =
             RPCBroker.handle_update(
               turn,
               %{
                 "operation" => "set_summary",
                 "entry_id" => Ecto.UUID.generate(),
                 "summary" => "A temporary tool failure",
                 "expected_entry_lock_version" => 1
               },
               "worker-route"
             )

    assert {:error, %{"code" => "source_learning_citation_required"}} =
             RPCBroker.handle_update(
               turn,
               %{
                 "operation" => "create_entry",
                 "name" => "Unsupported runtime state",
                 "type" => "fact",
                 "initial_body" => "The PDF reader is currently broken."
               },
               "worker-route"
             )

    assert {:ok, result} =
             RPCBroker.handle_update(
               turn,
               %{
                 "operation" => "create_entry",
                 "name" => "Supported source policy",
                 "type" => "fact",
                 "initial_body" => "Keep supported claims. src:#{source.document_id}"
               },
               "worker-route"
             )

    [created] = result["results"]

    assert {:ok, [audit]} =
             Knowledge.list_audit(scope,
               action: "create_entry",
               entry_id: created["entry_id"],
               limit: 1
             )

    assert audit.metadata["source_document_id"] == source.document_id
  end

  test "RPC chat recall follows the root turn's visible Response chain across session reset" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "brain-conversation-recall", :record_only)

    %{actor_event: old_event} =
      emit_addressed_actor_event(
        agent.uid,
        "brain-conversation-recall",
        group_entry(%{
          source_event_id: "brain-old-request-event",
          source_entry_id: "brain-old-request",
          explicit: true,
          text: "请整理上一周的研究记录"
        }),
        base_time()
      )

    {:ok, old_conversation} =
      Conversations.ensure_conversation(agent.uid, old_event.session_id,
        metadata: brain_metadata(old_event.signal_channel_id)
      )

    old_response =
      complete_response!(
        agent.uid,
        old_conversation.id,
        old_event.id,
        nil,
        "旧会话报告包含玄武岩映射结论"
      )

    assert {:ok, %{signal_entry: old_report}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-conversation-recall",
               group_entry(%{
                 source_event_id: "brain-old-report-event",
                 source_entry_id: "brain-old-report",
                 text: "旧会话报告包含玄武岩映射结论",
                 author: %{principal_uid: agent.uid, display_name: "Agent"},
                 provider_time: DateTime.add(base_time(), 1, :second)
               }),
               now: DateTime.add(base_time(), 1, :second)
             )

    old_report
    |> SignalEntry.changeset(%{ai_message_id: old_response.id})
    |> Repo.update!()

    old_conversation
    |> Ecto.Changeset.change(ended_at: DateTime.add(base_time(), 2, :second))
    |> Repo.update!()

    {:ok, current_conversation} =
      Conversations.ensure_conversation(agent.uid, old_event.session_id,
        metadata: brain_metadata(old_event.signal_channel_id)
      )

    insert_channel_context_fillers!(
      old_event.signal_channel_id,
      20,
      DateTime.add(base_time(), 2_000_000, :microsecond)
    )

    %{actor_event: visible_event} =
      emit_addressed_actor_event(
        agent.uid,
        "brain-conversation-recall",
        group_entry(%{
          source_event_id: "brain-current-visible-event",
          source_entry_id: "brain-current-visible-request",
          explicit: true,
          text: "当前链问题包含云杉坐标",
          provider_time: DateTime.add(base_time(), 3, :second)
        }),
        DateTime.add(base_time(), 3, :second)
      )

    refute Enum.any?(
             get_in(visible_event.payload, ["data", "channel_context", "messages"]),
             &(&1["source_entry_id"] == old_report.source_entry_id)
           )

    visible_response =
      complete_response!(
        agent.uid,
        current_conversation.id,
        visible_event.id,
        nil,
        "当前链回答包含云杉坐标"
      )

    assert {:ok, %{signal_entry: visible_report}} =
             Ingress.emit_entry(
               agent.uid,
               "brain-conversation-recall",
               group_entry(%{
                 source_event_id: "brain-current-report-event",
                 source_entry_id: "brain-current-report",
                 text: "当前链回答包含云杉坐标",
                 author: %{principal_uid: agent.uid, display_name: "Agent"},
                 provider_time: DateTime.add(base_time(), 4, :second)
               }),
               now: DateTime.add(base_time(), 4, :second)
             )

    visible_report
    |> SignalEntry.changeset(%{ai_message_id: visible_response.id})
    |> Repo.update!()

    %{actor_event: search_event} =
      emit_addressed_actor_event(
        agent.uid,
        "brain-conversation-recall",
        group_entry(%{
          source_event_id: "brain-search-event",
          source_entry_id: "brain-search-request",
          explicit: true,
          text: "帮我找玄武岩映射报告",
          provider_time: DateTime.add(base_time(), 5, :second)
        }),
        DateTime.add(base_time(), 5, :second)
      )

    assert {:ok, _search_response} =
             StatefulResponses.start_response_run(%{
               subject_uid: agent.uid,
               previous_response_id: "resp_#{visible_response.id}",
               metadata: %{"request_metadata" => %{"actor_event_id" => search_event.id}},
               request_items: [
                 %{
                   "type" => "message",
                   "role" => "user",
                   "content" => [%{"type" => "input_text", "text" => "search input"}]
                 }
               ]
             })

    turn = turn_ref(agent.uid, search_event.session_id, search_event.id)

    assert {:ok, old_result} =
             RPCBroker.handle_search(
               turn,
               %{
                 "query" => "玄武岩映射",
                 "layer" => "chat",
                 "channel_scope" => "current_channel"
               },
               "worker-route"
             )

    assert Enum.any?(old_result["results"], fn hit ->
             hit["layer"] == "chat" and
               Enum.any?(hit["messages"], &(&1["document_id"] == old_report.document_id))
           end)

    assert {:ok, visible_result} =
             RPCBroker.handle_search(
               turn,
               %{
                 "query" => "云杉坐标",
                 "layer" => "chat",
                 "channel_scope" => "current_channel"
               },
               "worker-route"
             )

    refute Enum.any?(visible_result["results"], fn hit ->
             hit["layer"] == "chat" and
               Enum.any?(hit["messages"], &(&1["document_id"] == visible_report.document_id))
           end)
  end

  defp complete_response!(agent_uid, conversation_id, actor_event_id, previous_id, text) do
    attrs = %{
      subject_uid: agent_uid,
      metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}},
      request_items: [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "actor input"}]
        }
      ]
    }

    attrs =
      if previous_id do
        Map.put(attrs, :previous_response_id, "resp_#{previous_id}")
      else
        Map.put(attrs, :conversation_id, conversation_id)
      end

    {:ok, response} = StatefulResponses.start_response_run(attrs)

    {:ok, response} =
      StatefulResponses.commit_complete(response, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ])

    response
  end

  defp brain_metadata(channel_id) do
    %{
      "brain" => %{
        "visibility" => "public",
        "channel_id" => channel_id,
        "channel_kind" => "im_group"
      }
    }
  end

  defp insert_channel_context_fillers!(channel_id, count, first_at) do
    Enum.each(1..count, fn index ->
      observed_at = DateTime.add(first_at, index, :millisecond)

      Repo.insert!(%SignalEntry{
        signal_channel_id: channel_id,
        source_entry_id: "brain-context-filler-#{index}",
        provider_thread_id: "brain-context-filler-thread-#{index}",
        text: "最近群聊占位消息 #{index}",
        attachments: [],
        links: [],
        author: %{principal_uid: "context-filler", display_name: "Context Filler"},
        mentions: [],
        metadata: %{},
        raw_payload: %{},
        provider_time: observed_at,
        reactions: %{},
        raw_reaction_keys: %{},
        document_id: "doc-brain-context-filler-#{index}",
        content_hash: "hash-brain-context-filler-#{index}",
        first_seen_at: observed_at,
        last_seen_at: observed_at,
        inserted_at: observed_at,
        updated_at: observed_at
      })
    end)
  end

  defp turn_ref(agent_uid, session_id, actor_event_id \\ Ecto.UUID.generate()) do
    %TurnRef{
      agent_uid: agent_uid,
      session_id: session_id,
      activation_uid: "brain-runtime-test",
      actor_epoch: 1,
      actor_event_id: actor_event_id,
      revision: 0
    }
  end
end
