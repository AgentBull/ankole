defmodule Ankole.AIGateway.StatefulResponsesTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.Channel

  describe "start_response_run/1" do
    test "creates a generating message row with metadata.actor_event_id" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-1")

      {:ok, message} = start_run(agent, conversation, "event-123")

      assert message.status == "generating"
      assert message.type == "message"

      assert Repo.get!(ActorEvent, message.metadata["actor_event_id"]).source_event_id ==
               "event-123"

      assert is_nil(message.previous_message_id)
    end

    test "records request-side tool result metadata when creating a run" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-tool-results")

      request_items = [
        %{
          "type" => "function_call_output",
          "id" => "fco_1",
          "call_id" => "call_1",
          "status" => "completed",
          "output" => "lookup result"
        }
      ]

      {:ok, message} =
        start_run(agent, conversation, "event-tool-results", %{request_items: request_items})

      assert message.content == request_items

      assert message.metadata["tool_results"] == [
               %{
                 "id" => "fco_1",
                 "call_id" => "call_1",
                 "status" => "completed",
                 "output" => "lookup result"
               }
             ]
    end

    test "decodes previous_response_id to previous_message_id" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-2")

      # First: create an initial message and mark it complete.
      {:ok, first} = start_run(agent, conversation, "event-a")

      {:ok, first_complete} = StatefulResponses.commit_complete(first, [%{"type" => "message"}])

      # Now start a second run referencing the first as previous_response_id.
      # The conversation is derived from the stored anchor; callers must not send
      # both previous_response_id and conversation.
      {:ok, second} =
        start_run(agent, conversation, "event-b", %{
          previous_response_id: "resp_#{first_complete.id}"
        })

      assert second.previous_message_id == first_complete.id
      assert second.conversation_id == conversation.id
    end

    test "rejects previous_response_id and conversation together" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-xor")

      {:ok, first} = start_run(agent, conversation, "event-xor-a")
      {:ok, first_complete} = StatefulResponses.commit_complete(first, [%{"type" => "message"}])

      actor_event =
        actor_event_fixture(agent.principal.uid, conversation.conversation_key, "event-xor-b")

      assert {:error, :stateful_anchor_conflict} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: actor_event.id,
                 previous_response_id: "resp_#{first_complete.id}"
               })
    end

    test "rejects non-complete anchor instead of silently rebasing" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-3")

      # Create a generating (not complete) message.
      {:ok, incomplete} = start_run(agent, conversation, "event-c")

      assert {:error, :invalid_anchor} =
               start_run(agent, conversation, "event-d", %{
                 previous_response_id: "resp_#{incomplete.id}"
               })
    end

    test "rejects malformed previous_response_id instead of raising" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-malformed-anchor")

      assert {:error, :invalid_anchor} =
               start_run(agent, conversation, "event-malformed-anchor", %{
                 previous_response_id: "resp_not-a-uuid"
               })
    end

    test "rejects a conversation owned by another agent" do
      owner = agent_fixture()
      caller = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(owner.principal.uid, "test-conv-cross-agent")

      actor_event =
        actor_event_fixture(
          caller.principal.uid,
          conversation.conversation_key,
          "event-cross-agent"
        )

      assert {:error, :invalid_conversation} =
               StatefulResponses.start_response_run(%{
                 agent_uid: caller.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: actor_event.id
               })
    end

    test "stores actor_event_id as correlation metadata without session-scope authorization" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-actor-scope")

      wrong_session_event =
        actor_event_fixture(agent.principal.uid, "other-session", "event-wrong-session")

      assert {:ok, message} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: wrong_session_event.id
               })

      assert message.metadata["actor_event_id"] == wrong_session_event.id
    end

    test "does not use actor_event_id as an authorization claim" do
      owner = agent_fixture()
      caller = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(caller.principal.uid, "test-conv-actor-owner")

      other_agent_event =
        actor_event_fixture(
          owner.principal.uid,
          conversation.conversation_key,
          "event-other-agent"
        )

      assert {:ok, message} =
               StatefulResponses.start_response_run(%{
                 agent_uid: caller.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: other_agent_event.id
               })

      assert message.metadata["actor_event_id"] == other_agent_event.id
    end

    test "allows stateful run without actor_event_id when conversation is agent-scoped" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-without-event")

      assert {:ok, message} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 conversation_id: conversation.id
               })

      refute Map.has_key?(message.metadata, "actor_event_id")
    end

    test "rejects a second active response run for the same actor event" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-active-run")

      {:ok, message} = start_run(agent, conversation, "event-active-run")
      actor_event_id = message.metadata["actor_event_id"]

      assert {:error, :response_run_in_progress} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: actor_event_id
               })

      assert Repo.get!(Message, message.id).status == "generating"
    end

    test "maps generating actor event unique index violations into changeset errors" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-active-run-index")

      {:ok, message} = start_run(agent, conversation, "event-active-run-index")
      actor_event_id = message.metadata["actor_event_id"]

      duplicate_changeset =
        Message.changeset(%Message{}, %{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          type: "message",
          status: "generating",
          content: [],
          metadata: %{"actor_event_id" => actor_event_id}
        })

      assert {:error, changeset} = Repo.insert(duplicate_changeset)

      assert Enum.any?(changeset.errors, fn
               {:metadata, {_message, opts}} ->
                 opts[:constraint] == :unique and
                   opts[:constraint_name] ==
                     "ai_gateway_messages_generating_actor_event_index"

               _error ->
                 false
             end)
    end

    test "fails a stale orphaned generating run before retrying from the same complete anchor" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-stale-run")

      {:ok, anchor} = start_run(agent, conversation, "event-stale-anchor")
      {:ok, anchor} = StatefulResponses.commit_complete(anchor, [%{"type" => "message"}])

      {:ok, stale} =
        start_run(agent, conversation, "event-stale-run", %{
          previous_response_id: "resp_#{anchor.id}"
        })

      actor_event_id = stale.metadata["actor_event_id"]
      mark_message_stale!(stale)

      request_items = [
        %{"type" => "function_call_output", "call_id" => "call_1", "output" => "ok"}
      ]

      assert {:ok, retried} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 actor_event_id: actor_event_id,
                 previous_response_id: "resp_#{anchor.id}",
                 request_items: request_items
               })

      assert retried.id != stale.id
      assert retried.previous_message_id == anchor.id
      assert retried.content == request_items

      stale = Repo.get!(Message, stale.id)
      assert stale.status == "error"
      assert stale.metadata["error"]["code"] == "stale_generating_response"
      assert stale.metadata["error"]["stage"] == "stateful_response_start"
      assert is_nil(Repo.get!(ActorEvent, actor_event_id).completed_at)
    end

    test "does not reclaim a stale generating run while a live delivery fence exists" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-stale-live-run")

      {:ok, message} = start_run(agent, conversation, "event-stale-live-run")
      actor_event = Repo.get!(ActorEvent, message.metadata["actor_event_id"])
      insert_live_delivery!(actor_event)
      mark_message_stale!(message)

      assert {:error, :response_run_in_progress} =
               StatefulResponses.start_response_run(%{
                 agent_uid: agent.principal.uid,
                 conversation_id: conversation.id,
                 actor_event_id: actor_event.id
               })

      assert Repo.get!(Message, message.id).status == "generating"
      assert live_delivery_count(actor_event.id) == 1
    end
  end

  describe "record_tool_results/1" do
    test "writes an idempotent completed tool-result journal row after an anchor" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-tool-journal")

      {:ok, anchor} = start_run(agent, conversation, "event-tool-journal-anchor")

      {:ok, anchor} =
        StatefulResponses.commit_complete(anchor, [
          %{
            "type" => "function_call",
            "call_id" => "call_1",
            "name" => "lookup",
            "arguments" => "{}"
          }
        ])

      actor_event =
        actor_event_fixture(
          agent.principal.uid,
          conversation.conversation_key,
          "event-tool-journal"
        )

      request_items = [
        %{"type" => "function_call_output", "call_id" => "call_1", "output" => "sunny"},
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "tool image summary"}]
        }
      ]

      attrs = %{
        agent_uid: agent.principal.uid,
        actor_event_id: actor_event.id,
        previous_response_id: "resp_#{anchor.id}",
        request_items: request_items
      }

      assert {:ok, journal} = StatefulResponses.record_tool_results(attrs)
      assert journal.status == "complete"
      assert journal.type == "message"
      assert journal.previous_message_id == anchor.id
      assert journal.content == request_items
      assert journal.metadata["actor_event_id"] == actor_event.id
      assert journal.metadata["tool_result_journal"] == true

      assert journal.metadata["tool_results"] == [
               %{"call_id" => "call_1", "output" => "sunny"}
             ]

      assert StatefulResponses.latest_visible_leaf(conversation.id) == journal.id

      assert Enum.map(StatefulResponses.expand_history(conversation.id), & &1.id) == [
               anchor.id,
               journal.id
             ]

      assert {:ok, duplicate} = StatefulResponses.record_tool_results(attrs)
      assert duplicate.id == journal.id

      assert Repo.aggregate(
               from(message in Message,
                 where:
                   fragment("?->>'tool_result_idempotency_key'", message.metadata) ==
                     ^journal.metadata["tool_result_idempotency_key"]
               ),
               :count
             ) == 1
    end

    test "rejects records that do not contain a tool output" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-invalid-tool-journal"
        )

      {:ok, anchor} = start_run(agent, conversation, "event-invalid-tool-journal-anchor")
      {:ok, anchor} = StatefulResponses.commit_complete(anchor, [%{"type" => "message"}])

      actor_event =
        actor_event_fixture(
          agent.principal.uid,
          conversation.conversation_key,
          "event-invalid-tool-journal"
        )

      assert {:error, :invalid_tool_results} =
               StatefulResponses.record_tool_results(%{
                 agent_uid: agent.principal.uid,
                 actor_event_id: actor_event.id,
                 previous_response_id: "resp_#{anchor.id}",
                 request_items: [%{"type" => "message", "role" => "user", "content" => "steer"}]
               })
    end
  end

  describe "commit_complete/3" do
    test "flips status to complete and appends terminal items to request content" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-4")

      request_items = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Ping"}]
        }
      ]

      {:ok, message} =
        start_run(agent, conversation, "event-e", %{
          request_items: request_items
        })

      output_items = [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hello"}]}
      ]

      {:ok, committed} =
        StatefulResponses.commit_complete(message, output_items, %{"usage" => %{}})

      assert committed.status == "complete"
      assert committed.content == request_items ++ output_items
      assert committed.metadata["usage"] == %{}
    end

    test "marks the actor event completed and removes live delivery when no function call remains" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-complete-event")

      {:ok, message} = start_run(agent, conversation, "event-complete-event")
      actor_event = Repo.get!(ActorEvent, message.metadata["actor_event_id"])
      insert_live_delivery!(actor_event)

      output_items = [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "done"}]}
      ]

      assert {:ok, committed} = StatefulResponses.commit_complete(message, output_items)
      assert committed.status == "complete"
      assert %DateTime{} = Repo.get!(ActorEvent, actor_event.id).completed_at
      assert live_delivery_count(actor_event.id) == 0
    end

    test "rejects completion when the source provider entry was tombstoned" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-tombstoned-event")

      actor_event =
        actor_event_fixture(
          agent.principal.uid,
          conversation.conversation_key,
          "event-tombstoned-complete",
          %{
            binding_name: "bot",
            signal_channel_id: "lark:chat:group-a",
            source_entry_id: "msg-tombstoned-complete"
          }
        )

      {:ok, message} =
        StatefulResponses.start_response_run(%{
          agent_uid: agent.principal.uid,
          conversation_id: conversation.id,
          actor_event_id: actor_event.id
        })

      insert_live_delivery!(actor_event)

      %Channel{}
      |> Channel.changeset(%{
        id: "lark:chat:group-a",
        kind: :im_group,
        reply_mode: :entry,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: DateTime.utc_now(:microsecond),
        last_seen_at: DateTime.utc_now(:microsecond)
      })
      |> Repo.insert!()

      %InputTombstone{}
      |> InputTombstone.changeset(%{
        agent_uid: agent.principal.uid,
        binding_name: "bot",
        signal_channel_id: "lark:chat:group-a",
        source_entry_id: "msg-tombstoned-complete",
        tombstoned_until: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
      })
      |> Repo.insert!()

      output_items = [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "done"}]}
      ]

      assert {:error, :actor_event_canceled} =
               StatefulResponses.commit_complete(message, output_items)

      assert %Message{status: "generating"} = Repo.get!(Message, message.id)
      assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
      assert live_delivery_count(actor_event.id) == 1
    end

    test "keeps the actor event live when the provider returns a function call" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-function-call-event"
        )

      {:ok, message} = start_run(agent, conversation, "event-function-call-event")
      actor_event = Repo.get!(ActorEvent, message.metadata["actor_event_id"])
      insert_live_delivery!(actor_event)

      output_items = [
        %{
          "type" => "function_call",
          "call_id" => "call_1",
          "name" => "lookup",
          "arguments" => "{}"
        }
      ]

      assert {:ok, committed} = StatefulResponses.commit_complete(message, output_items)
      assert committed.status == "complete"
      assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
      assert live_delivery_count(actor_event.id) == 1
    end

    test "keeps the actor event live when provider output mixes message and function call" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-message-and-function-call-event"
        )

      {:ok, message} = start_run(agent, conversation, "event-message-and-function-call")
      actor_event = Repo.get!(ActorEvent, message.metadata["actor_event_id"])
      insert_live_delivery!(actor_event)

      output_items = [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "I will check that."}]
        },
        %{
          "type" => "function_call",
          "call_id" => "call_mixed",
          "name" => "lookup",
          "arguments" => "{}"
        }
      ]

      assert {:ok, committed} = StatefulResponses.commit_complete(message, output_items)
      assert committed.status == "complete"
      assert is_nil(Repo.get!(ActorEvent, actor_event.id).completed_at)
      assert live_delivery_count(actor_event.id) == 1
    end

    test "completes the actor event when provider output is completed assistant text" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-assistant-text-completion-event"
        )

      {:ok, message} = start_run(agent, conversation, "event-assistant-text-completion")
      actor_event = Repo.get!(ActorEvent, message.metadata["actor_event_id"])
      insert_live_delivery!(actor_event)

      assistant_text = "文件已创建并验证。正在将其作为附件发送。"

      output_items = [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [
            %{
              "type" => "output_text",
              "text" => assistant_text
            }
          ]
        }
      ]

      assert {:ok, committed} = StatefulResponses.commit_complete(message, output_items)
      assert committed.status == "complete"
      assert Repo.get!(ActorEvent, actor_event.id).completed_at
      assert live_delivery_count(actor_event.id) == 0
    end

    test "returns already_terminal when another terminal transition won first" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-terminal-race")

      {:ok, message} = start_run(agent, conversation, "event-terminal-race")

      assert {:ok, _failed} = StatefulResponses.commit_error(message, [], %{"reason" => "closed"})
      assert {:ok, :already_terminal} = StatefulResponses.commit_complete(message, [])
    end
  end

  describe "commit_error/3" do
    test "flips status to error and preserves request content with partial output" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-5")

      request_items = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "Ping"}]
        }
      ]

      {:ok, message} =
        start_run(agent, conversation, "event-f", %{
          request_items: request_items
        })

      error = %{"code" => "rate_limit", "message" => "Too many requests"}

      partial_output = [
        %{"type" => "message", "content" => [%{"type" => "output_text", "text" => "Hel"}]}
      ]

      {:ok, failed} = StatefulResponses.commit_error(message, partial_output, error)

      assert failed.status == "error"
      assert failed.content == request_items ++ partial_output
      assert failed.metadata["error"]["code"] == "rate_limit"
      assert %DateTime{} = Repo.get!(ActorEvent, message.metadata["actor_event_id"]).completed_at
    end

    test "can keep the actor event open for socket-open retryable failures" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-socket-open-retry")

      {:ok, message} = start_run(agent, conversation, "event-socket-open-retry")

      {:ok, failed} =
        StatefulResponses.commit_error(
          message,
          [],
          %{"code" => "upstream_response_failed", "stage" => "socket_open"},
          complete_actor_event?: false
        )

      assert failed.status == "error"
      assert failed.metadata["error"]["stage"] == "socket_open"
      assert is_nil(Repo.get!(ActorEvent, message.metadata["actor_event_id"]).completed_at)
    end
  end

  describe "expand_history/2" do
    test "returns complete message chain in chronological order" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-6")

      # Build a 3-message chain.
      {:ok, m1} = start_run(agent, conversation, "event-g")

      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "first"}])

      {:ok, m2} =
        start_run(agent, conversation, "event-h", %{
          previous_response_id: "resp_#{m1.id}"
        })

      {:ok, m2} = StatefulResponses.commit_complete(m2, [%{"text" => "second"}])

      {:ok, m3} =
        start_run(agent, conversation, "event-i", %{
          previous_response_id: "resp_#{m2.id}"
        })

      {:ok, m3} = StatefulResponses.commit_complete(m3, [%{"text" => "third"}])

      history = StatefulResponses.expand_history(conversation.id)

      assert length(history) == 3
      # Chronological order: oldest first.
      assert hd(history).id == m1.id
      assert List.last(history).id == m3.id
    end

    test "excludes generating rows by default" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-7")

      {:ok, m1} = start_run(agent, conversation, "event-j")

      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "done"}])

      # Start a second run but don't commit it.
      {:ok, _m2} =
        start_run(agent, conversation, "event-k", %{
          previous_response_id: "resp_#{m1.id}"
        })

      history = StatefulResponses.expand_history(conversation.id)

      # Only the complete row should appear.
      assert length(history) == 1
    end

    test "rejects generating rows as explicit history anchors" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-generating-anchor")

      {:ok, m1} = start_run(agent, conversation, "event-generating-anchor-a")
      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "done"}])

      {:ok, generating} =
        start_run(agent, conversation, "event-generating-anchor-b", %{
          previous_response_id: "resp_#{m1.id}"
        })

      assert [] =
               StatefulResponses.expand_history(conversation.id,
                 previous_response_id: "resp_#{generating.id}"
               )
    end

    test "returns an empty history for malformed previous_response_id instead of raising" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-bad-history-anchor")

      assert [] =
               StatefulResponses.expand_history(conversation.id,
                 previous_response_id: "resp_not-a-uuid"
               )
    end

    test "projects checkpoint as artifact boundary while artifact preserves retained tail" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-compaction-tail")

      {:ok, m1} = start_run(agent, conversation, "event-compact-1")
      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "one"}])

      {:ok, m2} =
        start_run(agent, conversation, "event-compact-2", %{
          previous_response_id: "resp_#{m1.id}"
        })

      {:ok, m2} = StatefulResponses.commit_complete(m2, [%{"text" => "two"}])

      {:ok, m3} =
        start_run(agent, conversation, "event-compact-3", %{
          previous_response_id: "resp_#{m2.id}"
        })

      {:ok, m3} = StatefulResponses.commit_complete(m3, [%{"text" => "three"}])

      {:ok, m4} =
        start_run(agent, conversation, "event-compact-4", %{
          previous_response_id: "resp_#{m3.id}"
        })

      {:ok, m4} = StatefulResponses.commit_complete(m4, [%{"text" => "four"}])

      {:ok, m5} =
        start_run(agent, conversation, "event-compact-5", %{
          previous_response_id: "resp_#{m4.id}"
        })

      {:ok, m5} = StatefulResponses.commit_complete(m5, [%{"text" => "five"}])

      {:ok, artifact} =
        insert_compaction_artifact(
          agent,
          conversation,
          "one through three",
          m4.content ++ m5.content
        )

      {:ok, checkpoint} =
        StatefulResponses.create_compaction_checkpoint(%{
          agent_uid: agent.principal.uid,
          previous_response_id: "resp_#{m5.id}",
          artifact: artifact
        })

      history =
        StatefulResponses.expand_history(conversation.id,
          previous_response_id: "resp_#{checkpoint.id}"
        )

      assert Enum.map(history, & &1.id) == [checkpoint.id]
      assert checkpoint.content == [CompactionArtifacts.ref_item(artifact.id)]

      assert [
               %{
                 "id" => compaction_item_id,
                 "type" => "compaction",
                 "encrypted_content" => encrypted_content
               }
               | retained_tail
             ] = artifact.content["output"]

      assert is_binary(compaction_item_id)
      assert encrypted_content == "ankole:compact:v1:#{compaction_item_id}"
      assert retained_tail == m4.content ++ m5.content
    end

    test "projects covered function call when compaction tail keeps its tool result" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-compaction-tool-tail"
        )

      {:ok, m1} = start_run(agent, conversation, "event-compact-tool-1")
      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "one"}])

      function_call = [
        %{
          "type" => "function_call",
          "call_id" => "call_compacted",
          "name" => "lookup",
          "arguments" => "{}"
        }
      ]

      {:ok, m2} =
        start_run(agent, conversation, "event-compact-tool-2", %{
          previous_response_id: "resp_#{m1.id}"
        })

      {:ok, m2} = StatefulResponses.commit_complete(m2, function_call)

      tool_result = [
        %{
          "type" => "function_call_output",
          "call_id" => "call_compacted",
          "output" => "lookup result"
        }
      ]

      {:ok, m3} =
        start_run(agent, conversation, "event-compact-tool-3", %{
          previous_response_id: "resp_#{m2.id}"
        })

      {:ok, m3} = StatefulResponses.commit_complete(m3, tool_result)

      {:ok, m4} =
        start_run(agent, conversation, "event-compact-tool-4", %{
          previous_response_id: "resp_#{m3.id}"
        })

      {:ok, m4} = StatefulResponses.commit_complete(m4, [%{"text" => "four"}])

      {:ok, artifact} =
        insert_compaction_artifact(
          agent,
          conversation,
          "one through call",
          function_call ++ tool_result ++ m4.content
        )

      {:ok, checkpoint} =
        StatefulResponses.create_compaction_checkpoint(%{
          agent_uid: agent.principal.uid,
          previous_response_id: "resp_#{m4.id}",
          artifact: artifact
        })

      history =
        StatefulResponses.expand_history(conversation.id,
          previous_response_id: "resp_#{checkpoint.id}"
        )

      assert Enum.map(history, & &1.id) == [checkpoint.id]

      assert Enum.drop(artifact.content["output"], 1) ==
               function_call ++ tool_result ++ m4.content
    end

    test "projects covered function call when protected current input keeps its tool result" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-compaction-current-tool"
        )

      {:ok, m1} = start_run(agent, conversation, "event-current-tool-1")
      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "one"}])

      function_call = [
        %{
          "type" => "function_call",
          "call_id" => "call_current_input",
          "name" => "lookup",
          "arguments" => "{}"
        }
      ]

      {:ok, m2} =
        start_run(agent, conversation, "event-current-tool-2", %{
          previous_response_id: "resp_#{m1.id}"
        })

      {:ok, m2} = StatefulResponses.commit_complete(m2, function_call)

      {:ok, artifact} =
        insert_compaction_artifact(agent, conversation, "one through call", function_call)

      {:ok, checkpoint} =
        StatefulResponses.create_compaction_checkpoint(%{
          agent_uid: agent.principal.uid,
          previous_response_id: "resp_#{m2.id}",
          artifact: artifact
        })

      tool_result = [
        %{
          "type" => "function_call_output",
          "call_id" => "call_current_input",
          "output" => "lookup result"
        }
      ]

      history =
        StatefulResponses.expand_history(conversation.id,
          previous_response_id: "resp_#{checkpoint.id}",
          protected_tail_items: tool_result
        )

      assert Enum.map(history, & &1.id) == [checkpoint.id]
      assert Enum.drop(artifact.content["output"], 1) == function_call
    end
  end

  describe "latest_visible_leaf/1" do
    test "returns the latest complete leaf message" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-8")

      {:ok, m1} = start_run(agent, conversation, "event-l")

      {:ok, m1} = StatefulResponses.commit_complete(m1, [%{"text" => "first"}])

      {:ok, m2} =
        start_run(agent, conversation, "event-m", %{
          previous_response_id: "resp_#{m1.id}"
        })

      {:ok, m2} = StatefulResponses.commit_complete(m2, [%{"text" => "second"}])

      leaf = StatefulResponses.latest_visible_leaf(conversation.id)
      assert leaf == m2.id
    end

    test "returns the latest branch leaf deterministically when multiple leaves exist" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-branch-leaves")

      {:ok, root} = start_run(agent, conversation, "event-branch-root")
      {:ok, root} = StatefulResponses.commit_complete(root, [%{"text" => "root"}])

      {:ok, older_leaf} =
        start_run(agent, conversation, "event-branch-older", %{
          previous_response_id: "resp_#{root.id}"
        })

      {:ok, older_leaf} = StatefulResponses.commit_complete(older_leaf, [%{"text" => "older"}])

      {:ok, latest_leaf} =
        start_run(agent, conversation, "event-branch-latest", %{
          previous_response_id: "resp_#{root.id}"
        })

      {:ok, latest_leaf} =
        StatefulResponses.commit_complete(latest_leaf, [%{"text" => "latest"}])

      assert StatefulResponses.latest_visible_leaf(conversation.id) == latest_leaf.id

      assert Enum.map(StatefulResponses.expand_history(conversation.id), & &1.id) == [
               root.id,
               latest_leaf.id
             ]

      assert Enum.map(
               StatefulResponses.expand_history(conversation.id,
                 previous_response_id: "resp_#{older_leaf.id}"
               ),
               & &1.id
             ) == [root.id, older_leaf.id]
    end

    test "returns nil for empty conversation" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-9")

      assert StatefulResponses.latest_visible_leaf(conversation.id) == nil
    end
  end

  defp start_run(agent, conversation, source_event_id, attrs \\ %{}) do
    actor_event =
      actor_event_fixture(agent.principal.uid, conversation.conversation_key, source_event_id)

    base = %{
      agent_uid: agent.principal.uid,
      actor_event_id: actor_event.id
    }

    base =
      if Map.has_key?(attrs, :previous_response_id) or Map.has_key?(attrs, "previous_response_id") do
        base
      else
        Map.put(base, :conversation_id, conversation.id)
      end

    StatefulResponses.start_response_run(Map.merge(base, attrs))
  end

  defp insert_compaction_artifact(agent, conversation, summary_text, retained_items) do
    CompactionArtifacts.insert_artifact(%{
      agent_uid: agent.principal.uid,
      conversation_id: conversation.id,
      summary_text: summary_text,
      retained_items: retained_items,
      retention: %{
        "strategy" => "tail_rows",
        "requested" => 2,
        "actual" => length(retained_items)
      },
      usage: %{}
    })
  end

  defp actor_event_fixture(agent_uid, session_id, source_event_id, attrs \\ %{}) do
    attrs =
      %{
        agent_uid: agent_uid,
        binding_name: "test-binding",
        session_id: session_id,
        source_event_id: source_event_id,
        type: "im.message.addressed",
        available_at: DateTime.utc_now(:microsecond),
        queue_sequence: System.unique_integer([:positive]),
        input_state: "open",
        payload: %{"text" => source_event_id}
      }
      |> Map.merge(attrs)

    %ActorEvent{}
    |> ActorEvent.changeset(attrs)
    |> Repo.insert!()
  end

  defp mark_message_stale!(%Message{} = message) do
    stale_at = DateTime.add(DateTime.utc_now(:microsecond), -600, :second)

    {1, _rows} =
      Message
      |> where([stored], stored.id == ^message.id)
      |> Repo.update_all(set: [updated_at: stale_at])

    :ok
  end

  defp insert_live_delivery!(%ActorEvent{} = actor_event) do
    %ActorEventDelivery{}
    |> ActorEventDelivery.changeset(%{
      actor_event_id: actor_event.id,
      agent_uid: actor_event.agent_uid,
      session_id: actor_event.session_id,
      queue_sequence: actor_event.queue_sequence,
      attempt_no: 1,
      actor_lane_message_id: "lane-#{actor_event.id}",
      activation_uid: "activation-#{actor_event.id}",
      actor_epoch: 1,
      actor_event_id_fence: actor_event.id,
      revision: 0,
      state: "accepted",
      error: %{}
    })
    |> Repo.insert!()
  end

  defp live_delivery_count(actor_event_id) do
    ActorEventDelivery
    |> where([delivery], delivery.actor_event_id_fence == ^actor_event_id)
    |> where([delivery], delivery.state in ^ActorEventDelivery.live_states())
    |> Repo.aggregate(:count)
  end
end
