defmodule Ankole.AIGateway.StatefulResponsesTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message

  describe "start_response_run/1" do
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

      assert {:error, :stateful_anchor_conflict} =
               StatefulResponses.start_response_run(%{
                 subject_uid: agent.principal.uid,
                 conversation_id: conversation.id,
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

      assert {:error, :invalid_conversation} =
               StatefulResponses.start_response_run(%{
                 subject_uid: caller.principal.uid,
                 conversation_id: conversation.id
               })
    end
  end

  describe "start_planned_response_run/1" do
    test "admits only one concurrent implicit continuation and commits its compaction atomically" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-implicit-admission"
        )

      {:ok, root} = start_run(agent, conversation, "event-implicit-admission-root")
      {:ok, root} = StatefulResponses.commit_complete(root, [%{"text" => "root"}])

      attrs = %{
        subject_uid: agent.principal.uid,
        conversation_id: conversation.id,
        expected_previous_response_id: "resp_#{root.id}",
        request_items: [%{"type" => "message", "role" => "user", "content" => []}],
        metadata: %{"request_metadata" => %{"source" => "implicit-admission-test"}},
        compaction: %{
          artifact_attrs: %{
            subject_uid: agent.principal.uid,
            conversation_id: conversation.id,
            summary_text: "Concurrent admission summary",
            retained_items: [],
            retained_user_originals: [],
            retention: %{},
            usage: %{}
          },
          checkpoint_metadata: %{"auto" => true}
        }
      }

      tasks =
        for _index <- 1..2 do
          Task.async(fn ->
            receive do
              :start -> StatefulResponses.start_planned_response_run(attrs)
            end
          end)
        end

      Enum.each(tasks, fn task ->
        :ok = Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
        send(task.pid, :start)
      end)

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert [{:ok, admitted}] = Enum.filter(results, &match?({:ok, %Message{}}, &1))
      assert [{:error, :response_run_in_progress}] = Enum.reject(results, &match?({:ok, _}, &1))

      assert [checkpoint] =
               Message
               |> where([message], message.conversation_id == ^conversation.id)
               |> where([message], message.type == "checkpoint")
               |> Repo.all()

      assert checkpoint.previous_message_id == root.id
      assert admitted.previous_message_id == checkpoint.id
      assert Repo.aggregate(CompactionArtifact, :count) == 1

      assert {:ok, explicit_branch} =
               StatefulResponses.start_response_run(%{
                 subject_uid: agent.principal.uid,
                 previous_response_id: "resp_#{root.id}",
                 metadata: %{"request_metadata" => %{"source" => "explicit-branch-test"}}
               })

      assert explicit_branch.previous_message_id == root.id
    end

    test "rejects an implicit plan when its derived leaf changed before admission" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(
          agent.principal.uid,
          "test-conv-implicit-head-change"
        )

      {:ok, root} = start_run(agent, conversation, "event-implicit-head-change-root")
      {:ok, root} = StatefulResponses.commit_complete(root, [%{"text" => "root"}])

      {:ok, newer_leaf} =
        start_run(agent, conversation, "event-implicit-head-change-newer", %{
          previous_response_id: "resp_#{root.id}"
        })

      {:ok, _newer_leaf} =
        StatefulResponses.commit_complete(newer_leaf, [%{"text" => "newer"}])

      assert {:error, :response_run_in_progress} =
               StatefulResponses.start_planned_response_run(%{
                 subject_uid: agent.principal.uid,
                 conversation_id: conversation.id,
                 expected_previous_response_id: "resp_#{root.id}",
                 request_items: [%{"type" => "message", "role" => "user", "content" => []}]
               })

      refute Repo.exists?(
               from(message in Message,
                 where:
                   message.conversation_id == ^conversation.id and
                     message.status == "generating"
               )
             )
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

      request_items = [
        %{"type" => "function_call_output", "call_id" => "call_1", "output" => "sunny"},
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => "tool image summary"}]
        }
      ]

      attrs = %{
        subject_uid: agent.principal.uid,
        previous_response_id: "resp_#{anchor.id}",
        request_items: request_items,
        metadata: %{"request_metadata" => %{"opaque" => "kept"}}
      }

      assert {:ok, journal} = StatefulResponses.record_tool_results(attrs)
      assert journal.status == "complete"
      assert journal.type == "message"
      assert journal.previous_message_id == anchor.id
      assert journal.content == request_items
      assert StatefulResponses.response_metadata(journal) == %{"opaque" => "kept"}
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

    test "deduplicates identical outputs before writing the canonical journal" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-tool-dedupe")

      {:ok, anchor} = start_run(agent, conversation, "event-tool-dedupe-anchor")

      {:ok, anchor} =
        StatefulResponses.commit_complete(anchor, [
          %{
            "type" => "function_call",
            "call_id" => "call_dedupe",
            "name" => "lookup",
            "arguments" => "{}"
          }
        ])

      output = %{
        "type" => "function_call_output",
        "call_id" => "call_dedupe",
        "output" => "sunny"
      }

      assert {:ok, journal} =
               StatefulResponses.record_tool_results(%{
                 subject_uid: agent.principal.uid,
                 previous_response_id: "resp_#{anchor.id}",
                 request_items: [output, output]
               })

      assert journal.status == "complete"
      assert journal.content == [output]
      assert StatefulResponses.latest_visible_leaf(conversation.id) == journal.id
    end

    test "quarantines orphan outputs as raw error rows outside canonical history" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-tool-quarantine")

      {:ok, anchor} = start_run(agent, conversation, "event-tool-quarantine-anchor")

      {:ok, anchor} =
        StatefulResponses.commit_complete(anchor, [
          %{"type" => "message", "role" => "assistant", "content" => "stable answer"}
        ])

      orphan = %{
        "type" => "function_call_output",
        "call_id" => "call_orphan",
        "output" => "side effect happened"
      }

      attrs = %{
        subject_uid: agent.principal.uid,
        previous_response_id: "resp_#{anchor.id}",
        request_items: [orphan]
      }

      assert {:error,
              {:tool_results_quarantined,
               %{
                 "reason" => "orphan_function_call_output",
                 "orphan_call_ids" => ["call_orphan"],
                 "quarantine_response_id" => quarantine_response_id,
                 "quarantine_status" => "error"
               }}} = StatefulResponses.record_tool_results(attrs)

      quarantine_id = String.replace_prefix(quarantine_response_id, "resp_", "")
      quarantined = Repo.get!(Message, quarantine_id)

      assert quarantined.status == "error"
      assert quarantined.previous_message_id == anchor.id
      assert quarantined.content == [orphan]

      assert quarantined.metadata["tool_result_quarantine"]["reason"] ==
               "orphan_function_call_output"

      assert StatefulResponses.latest_visible_leaf(conversation.id) == anchor.id
      assert Enum.map(StatefulResponses.expand_history(conversation.id), & &1.id) == [anchor.id]

      assert {:error,
              {:tool_results_quarantined, %{"quarantine_response_id" => ^quarantine_response_id}}} =
               StatefulResponses.record_tool_results(attrs)
    end

    test "quarantines outputs for explicitly incomplete calls" do
      agent = agent_fixture()

      {:ok, conversation} =
        StatefulResponses.ensure_conversation(agent.principal.uid, "test-conv-incomplete-call")

      {:ok, anchor} = start_run(agent, conversation, "event-incomplete-call-anchor")

      {:ok, anchor} =
        StatefulResponses.commit_complete(anchor, [
          %{
            "type" => "function_call",
            "status" => "incomplete",
            "call_id" => "call_incomplete",
            "name" => "patch",
            "arguments" => "{\"path\":\"/tmp/repor"
          }
        ])

      assert {:error,
              {:tool_results_quarantined,
               %{
                 "reason" => "non_executable_function_call_output",
                 "non_executable_call_ids" => ["call_incomplete"]
               }}} =
               StatefulResponses.record_tool_results(%{
                 subject_uid: agent.principal.uid,
                 previous_response_id: "resp_#{anchor.id}",
                 request_items: [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_incomplete",
                     "output" => "must not become canonical"
                   }
                 ]
               })
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

      assert {:error, :invalid_tool_results} =
               StatefulResponses.record_tool_results(%{
                 subject_uid: agent.principal.uid,
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
          subject_uid: agent.principal.uid,
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
          subject_uid: agent.principal.uid,
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
          subject_uid: agent.principal.uid,
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
    base = %{
      subject_uid: agent.principal.uid,
      metadata: %{"request_metadata" => %{"test_correlation" => source_event_id}}
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
      subject_uid: agent.principal.uid,
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
end
