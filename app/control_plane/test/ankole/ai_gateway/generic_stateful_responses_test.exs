defmodule Ankole.AIGateway.GenericStatefulResponsesTest do
  alias Ankole.AIGateway.ToolResultJournal
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ResponseChain
  use Ankole.DataCase, async: true

  import Ecto.Query, warn: false
  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo

  test "a takeover immediately reclaims a generating Response after admission (G6)" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "force-recovery")

    {:ok, live} =
      start_response_run(%{subject_uid: subject.uid, conversation_id: conversation.id})

    assert {:ok, :failed} = AIGateway.reconcile_orphaned_response(live.id, force: true)
    assert Repo.get!(Message, live.id).status == "error"
    assert {:ok, :already_terminal} = ResponseCommit.commit_complete(live, [])
  end

  test "caller metadata round-trips without colliding with response facts" do
    %{principal: subject} = human_fixture()
    caller_metadata = %{"usage" => "caller-value", "model" => "caller-model", "tag" => "kept"}

    {:ok, conversation} =
      Conversations.ensure_conversation(subject.uid, "generic-events")

    assert :ok = Events.subscribe(subject.uid, conversation.id)

    {:ok, response} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: %{
          "request_metadata" => caller_metadata,
          "usage" => %{"input_tokens" => 1}
        }
      })

    assert_receive {:ai_gateway_event, :response_started,
                    %{
                      subject_uid: subject_uid,
                      conversation_id: conversation_id,
                      response_id: response_id,
                      metadata: ^caller_metadata
                    }}

    assert subject_uid == subject.uid
    assert conversation_id == conversation.id
    assert response_id == "resp_#{response.id}"

    {:ok, completed} =
      ResponseCommit.commit_complete(response, [], %{
        "usage" => %{"input_tokens" => 9},
        "provider_model" => "provider-model"
      })

    assert ResponseChain.response_metadata(completed) == caller_metadata

    assert_receive {:ai_gateway_event, :response_completed,
                    %{response_id: ^response_id, metadata: ^caller_metadata}}
  end

  test "tool result journal is generic and response chain is final-first" do
    %{principal: subject} = human_fixture()

    {:ok, conversation} =
      Conversations.ensure_conversation(subject.uid, "generic-tool-journal")

    {:ok, response} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"request" => "one"}}
      })

    {:ok, completed} =
      ResponseCommit.commit_complete(response, [
        %{
          "type" => "function_call",
          "call_id" => "call_1",
          "name" => "generic_tool",
          "arguments" => "{}",
          "status" => "completed"
        }
      ])

    {:ok, journal} =
      record_tool_results(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{completed.id}",
        request_items: [
          %{
            "type" => "function_call_output",
            "call_id" => "call_1",
            "output" => "done"
          }
        ],
        metadata: %{"request_metadata" => %{"request" => "two"}}
      })

    assert journal.previous_message_id == completed.id
    assert ResponseChain.response_metadata(journal) == %{"request" => "two"}

    assert {:ok, [final, parent]} =
             ResponseChain.list_response_chain(subject.uid, "resp_#{journal.id}")

    assert final.id == journal.id
    assert parent.id == completed.id
  end

  test "orphan reconciliation depends only on Response status and heartbeat time" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "generic-orphan")

    {:ok, live} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id
      })

    now = DateTime.utc_now(:microsecond)

    Repo.update_all(from(message in Message, where: message.id == ^live.id),
      set: [updated_at: now]
    )

    assert {:ok, :live} =
             AIGateway.reconcile_orphaned_response(live.id,
               now: DateTime.add(now, 299, :second)
             )

    assert Repo.get!(Message, live.id).status == "generating"

    assert {:ok, :failed} =
             AIGateway.reconcile_orphaned_response(live.id,
               now: DateTime.add(now, 301, :second)
             )

    failed = Repo.get!(Message, live.id)
    assert failed.status == "error"
    assert failed.metadata["error"]["code"] == "orphaned_generating_response"
  end

  test "active conversation listing uses generic subject and key filters" do
    %{principal: subject} = human_fixture()
    %{principal: other_subject} = human_fixture()

    {:ok, selected} = Conversations.ensure_conversation(subject.uid, "selected")

    {:ok, _other} = Conversations.ensure_conversation(other_subject.uid, "selected")

    assert [conversation] =
             AIGateway.list_active_conversations(Repo,
               subject_uid: subject.uid,
               conversation_key: "selected",
               limit: 10
             )

    assert conversation.id == selected.id
    assert conversation.subject_uid == subject.uid
  end

  test "visible suffix deletion detaches non-complete descendants" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "suffix-detach")

    {:ok, anchor} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id
      })

    {:ok, anchor} = ResponseCommit.commit_complete(anchor, [])

    {:ok, child} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{anchor.id}"
      })

    assert {:ok, failed_child} =
             AIGateway.fail_generating_response(subject.uid, "resp_#{child.id}", %{
               "code" => "test_failure"
             })

    assert {:ok, %{status: :deleted, deleted_count: 1}} =
             Repo.transact(fn repo ->
               AIGateway.hard_delete_visible_suffix_in_tx(
                 repo,
                 subject.uid,
                 conversation.id,
                 ["resp_#{anchor.id}"]
               )
             end)

    refute Repo.get(Message, anchor.id)
    assert %{status: "error", previous_message_id: nil} = Repo.get!(Message, failed_child.id)
  end

  test "visible suffix retraction preserves audit rows and resumes from the predecessor" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "suffix-retract")

    {:ok, predecessor} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id
      })

    {:ok, predecessor} = ResponseCommit.commit_complete(predecessor, [])

    {:ok, first} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{predecessor.id}"
      })

    {:ok, first} = ResponseCommit.commit_complete(first, [])

    {:ok, second} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}"
      })

    {:ok, second} = ResponseCommit.commit_complete(second, [])
    retracted_at = DateTime.utc_now(:microsecond)

    assert {:ok,
            %{
              status: :retracted,
              retracted_count: 2,
              retracted_message_ids: [second_id, first_id]
            }} =
             Repo.transact(fn repo ->
               AIGateway.retract_visible_suffix_in_tx(
                 repo,
                 subject.uid,
                 conversation.id,
                 ["resp_#{second.id}", "resp_#{first.id}"],
                 reason: "command.retry",
                 retracted_at: retracted_at
               )
             end)

    assert [second_id, first_id] == [second.id, first.id]

    for response <- [first, second] do
      stored = Repo.get!(Message, response.id)
      assert stored.status == "retracted"
      assert stored.metadata["retraction"]["reason"] == "command.retry"
      assert stored.metadata["retraction"]["retracted_at"] == DateTime.to_iso8601(retracted_at)
    end

    assert ResponseChain.latest_visible_leaf(conversation.id) == predecessor.id
  end

  test "facade publishes a generic terminal event after an in-transaction failure" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "facade-publish")
    assert :ok = AIGateway.subscribe(subject.uid, conversation.id)

    {:ok, response} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"opaque" => "kept"}}
      })

    assert_receive {:ai_gateway_event, :response_started, _event}

    now = DateTime.utc_now(:microsecond)

    assert {:ok, failed} =
             Repo.transact(fn repo ->
               AIGateway.fail_generating_response_in_tx(
                 repo,
                 subject.uid,
                 "resp_#{response.id}",
                 %{"code" => "cancelled"},
                 now
               )
             end)

    assert :ok =
             AIGateway.publish_terminal_event(failed, :response_failed, %{
               error: failed.metadata["error"]
             })

    assert_receive {:ai_gateway_event, :response_failed,
                    %{response_id: response_id, metadata: %{"opaque" => "kept"}}}

    assert response_id == "resp_#{response.id}"
  end

  test "heartbeat replaces only upstream progress and terminal failures keep it" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "stream-progress")
    caller = %{"tag" => "kept", "upstream_progress" => "caller-owned"}

    {:ok, response} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: %{
          "request_metadata" => caller,
          "provider_model" => "kept-model",
          "upstream_progress" => %{"event_count" => 0}
        }
      })

    progress = %{"attempt" => 2, "event_count" => 3, "last_event_at" => "2026-10-12T00:00:00Z"}

    assert :ok =
             ResponseCommit.record_upstream_progress(
               subject.uid,
               "resp_#{response.id}",
               progress
             )

    recorded = Repo.get!(Message, response.id)
    assert recorded.updated_at == response.updated_at
    assert recorded.metadata["upstream_progress"] == progress
    assert recorded.metadata["request_metadata"] == caller
    assert recorded.metadata["provider_model"] == "kept-model"

    assert {:ok, touched} =
             ResponseCommit.touch_generating_response(
               subject.uid,
               "resp_#{response.id}",
               progress
             )

    assert touched.status == "generating"
    assert touched.metadata["upstream_progress"] == progress
    assert touched.metadata["request_metadata"] == caller
    assert touched.metadata["provider_model"] == "kept-model"

    assert {:ok, failed} =
             Repo.transact(fn repo ->
               ResponseCommit.fail_generating_response_in_tx(
                 repo,
                 subject.uid,
                 "resp_#{response.id}",
                 %{"code" => "cancelled"},
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert failed.metadata["upstream_progress"] == progress
    assert failed.metadata["request_metadata"] == caller

    assert {:error, :not_found} =
             ResponseCommit.record_upstream_progress(
               subject.uid,
               "resp_#{response.id}",
               %{"event_count" => 99}
             )

    assert {:ok, :already_terminal} =
             ResponseCommit.touch_generating_response(
               subject.uid,
               "resp_#{response.id}",
               %{"event_count" => 99}
             )

    assert Repo.get!(Message, response.id).metadata["upstream_progress"] == progress
  end

  defp record_tool_results(attrs) do
    {:ok, result} =
      Ankole.Repo.transact(fn repo ->
        {:ok, ToolResultJournal.record_tool_results_in_tx(repo, attrs)}
      end)

    case result do
      {:ok, message, _disposition} ->
        ToolResultJournal.publish_tool_result_events(message)
        {:ok, message}

      error ->
        error
    end
  end
end
