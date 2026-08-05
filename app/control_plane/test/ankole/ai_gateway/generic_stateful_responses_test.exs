defmodule Ankole.AIGateway.GenericStatefulResponsesTest do
  use Ankole.DataCase, async: true

  import Ecto.Query, warn: false
  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway
  alias Ankole.AIGateway.Events
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Repo

  test "caller metadata round-trips without colliding with response facts" do
    %{principal: subject} = human_fixture()
    caller_metadata = %{"usage" => "caller-value", "model" => "caller-model", "tag" => "kept"}

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(subject.uid, "generic-events")

    assert :ok = Events.subscribe(subject.uid, conversation.id)

    {:ok, response} =
      StatefulResponses.start_response_run(%{
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
      StatefulResponses.commit_complete(response, [], %{
        "usage" => %{"input_tokens" => 9},
        "provider_model" => "provider-model"
      })

    assert StatefulResponses.response_metadata(completed) == caller_metadata

    assert_receive {:ai_gateway_event, :response_completed,
                    %{response_id: ^response_id, metadata: ^caller_metadata}}
  end

  test "tool result journal is generic and response chain is final-first" do
    %{principal: subject} = human_fixture()

    {:ok, conversation} =
      StatefulResponses.ensure_conversation(subject.uid, "generic-tool-journal")

    {:ok, response} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"request" => "one"}}
      })

    {:ok, completed} =
      StatefulResponses.commit_complete(response, [
        %{
          "type" => "function_call",
          "call_id" => "call_1",
          "name" => "generic_tool",
          "arguments" => "{}",
          "status" => "completed"
        }
      ])

    {:ok, journal} =
      StatefulResponses.record_tool_results(%{
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
    assert StatefulResponses.response_metadata(journal) == %{"request" => "two"}

    assert {:ok, [final, parent]} =
             StatefulResponses.list_response_chain(subject.uid, "resp_#{journal.id}")

    assert final.id == journal.id
    assert parent.id == completed.id
  end

  test "orphan reconciliation depends only on Response status and heartbeat time" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "generic-orphan")

    {:ok, live} =
      StatefulResponses.start_response_run(%{
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

    {:ok, selected} = StatefulResponses.ensure_conversation(subject.uid, "selected")

    {:ok, _other} = StatefulResponses.ensure_conversation(other_subject.uid, "selected")

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
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "suffix-detach")

    {:ok, anchor} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id
      })

    {:ok, anchor} = StatefulResponses.commit_complete(anchor, [])

    {:ok, child} =
      StatefulResponses.start_response_run(%{
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
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "suffix-retract")

    {:ok, predecessor} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id
      })

    {:ok, predecessor} = StatefulResponses.commit_complete(predecessor, [])

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{predecessor.id}"
      })

    {:ok, first} = StatefulResponses.commit_complete(first, [])

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}"
      })

    {:ok, second} = StatefulResponses.commit_complete(second, [])
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

    assert StatefulResponses.latest_visible_leaf(conversation.id) == predecessor.id
  end

  test "facade publishes a generic terminal event after an in-transaction failure" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "facade-publish")
    assert :ok = AIGateway.subscribe(subject.uid, conversation.id)

    {:ok, response} =
      StatefulResponses.start_response_run(%{
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
end
