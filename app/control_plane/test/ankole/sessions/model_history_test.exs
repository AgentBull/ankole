defmodule Ankole.Sessions.ModelHistoryTest do
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ResponseChain
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias Ankole.Signals
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Conversations.Conversation, as: PublicConversation

  test "run recovery reads model output, recorded calls, without the live Response (G3)" do
    %{principal: subject} = human_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "run-recovery")

    metadata = %{
      "request_metadata" => %{"signal_id" => "event_1", "loop" => %{"iteration" => 1}}
    }

    {:ok, response} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: metadata
      })

    {:ok, completed} =
      ResponseCommit.commit_complete(response, [
        %{
          "type" => "function_call",
          "call_id" => "c1",
          "name" => "read_file",
          "arguments" => "{}",
          "status" => "completed"
        }
      ])

    {:ok, journal} =
      record_tool_results(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{completed.id}",
        metadata: metadata,
        request_items: [%{"type" => "function_call_output", "call_id" => "c1", "output" => "ok"}]
      })

    {:ok, _live} =
      start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: metadata
      })

    assert {:ok, tail} =
             Ankole.AIGateway.visible_response_suffix(
               conversation.subject_uid,
               conversation.id,
               {"signal_id", "event_1"}
             )

    assert Enum.map(tail.responses, & &1.id) == [completed.id]
    assert tail.recorded_call_ids == MapSet.new(["c1"])
    assert tail.leaf == journal.id

    assert {:ok, empty} =
             Ankole.AIGateway.visible_response_suffix(
               conversation.subject_uid,
               conversation.id,
               {"signal_id", "another_event"}
             )

    assert empty.responses == []
  end

  test "exact turn ownership rejects a composite turn" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "composite-replay")

    {:ok, response} =
      start_response(subject.uid, conversation.id, %{
        "signal_id" => "event-main",
        "request_refs" => [%{"signal_id" => "event-steer"}]
      })

    assert {:ok, _completed} =
             ResponseCommit.commit_complete(response, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "done"}]
               }
             ])

    session_key = %{agent_uid: subject.uid, session_id: conversation.conversation_key}

    assert {:ok, :checked} =
             Repo.transact(fn repo ->
               refute ModelHistory.exact_turn_retryable_in_tx(repo, session_key, "event-main")
               refute ModelHistory.exact_turn_retryable_in_tx(repo, session_key, "event-steer")
               {:ok, :checked}
             end)
  end

  test "retracts only the current actor-correlated visible suffix" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-retry-retract")

    {:ok, predecessor} =
      start_response(subject.uid, conversation.id, %{"signal_id" => "event-before"})

    {:ok, predecessor} = ResponseCommit.commit_complete(predecessor, [])

    {:ok, first} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{predecessor.id}",
        metadata: %{"request_metadata" => %{"signal_id" => "event-retry"}}
      })

    {:ok, first} = ResponseCommit.commit_complete(first, [])

    {:ok, second} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"signal_id" => "event-retry"}}
      })

    {:ok, second} = ResponseCommit.commit_complete(second, [])

    assert {:ok, %{status: :retracted, retracted_count: 2}} =
             Repo.transact(fn repo ->
               ModelHistory.retract_visible_turn_suffix_in_tx(
                 repo,
                 subject.uid,
                 conversation.conversation_key,
                 "event-retry",
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert Repo.get!(Message, predecessor.id).status == "complete"
    assert Repo.get!(Message, first.id).status == "retracted"
    assert Repo.get!(Message, second.id).status == "retracted"
    assert ResponseChain.latest_visible_leaf(conversation.id) == predecessor.id
  end

  test "selects an actor-correlated visible suffix before calling generic deletion" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-retraction")

    {:ok, first} =
      start_response(subject.uid, conversation.id, %{"signal_id" => "event-tail"})

    {:ok, first} = ResponseCommit.commit_complete(first, [])

    {:ok, second} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"signal_id" => "event-tail"}}
      })

    {:ok, second} = ResponseCommit.commit_complete(second, [])

    assert {:ok,
            %{
              status: :deleted,
              deleted_count: 2,
              failed_generating_count: 0,
              deleted_message_ids: deleted_ids
            }} =
             Repo.transact(fn repo ->
               ModelHistory.delete_visible_turn_suffix_in_tx(
                 repo,
                 subject.uid,
                 conversation.conversation_key,
                 "event-tail",
                 DateTime.utc_now(:microsecond)
               )
             end)

    assert MapSet.new(deleted_ids) == MapSet.new([first.id, second.id])
    refute Repo.get(Message, first.id)
    refute Repo.get(Message, second.id)
  end

  test "declares a DM conversation origin from the mirrored channel" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()
    now = DateTime.utc_now(:microsecond)
    channel_id = Ecto.UUID.generate()

    Repo.insert!(%PublicConversation{
      id: channel_id,
      kind: :external,
      external_kind: :im_dm,
      title: "DM",
      provider_conversation_id: "dm:#{channel_id}",
      last_activity_at: now,
      reply_mode: :entry,
      metadata: %{"dm_peer_principal_uid" => peer.uid},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })

    {:ok, signal} =
      accept_signal(%{
        target: %{agent_uid: agent.uid, session_id: "dm-session"},
        source: "test:im",
        subject: "dm-session",
        reply_route: %{
          binding_name: "test",
          conversation_id: channel_id,
          provider_message_id: "message-1"
        },
        id: "event-#{Ecto.UUID.generate()}",
        type: "conversation.message.addressed",
        available_at: now,
        sender: peer.uid,
        data: %{"entry" => %{"author" => %{"principal_uid" => peer.uid}}}
      })

    assert {:ok, conversation} =
             Repo.transact(fn repo ->
               ModelHistory.ensure_and_lock_conversation_in_tx(
                 repo,
                 agent.uid,
                 signal.session_id,
                 signal
               )
             end)

    assert conversation.metadata["origin"] == %{
             "peer_uid" => peer.uid,
             "conversation_id" => channel_id,
             "channel_kind" => "im_dm"
           }

    assert %{"origin" => successor_origin} =
             ModelHistory.successor_origin_metadata(conversation)

    assert successor_origin == conversation.metadata["origin"]
  end

  test "scheduled work without a source conversation starts with no declared origin" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    for type <- ["check_back_later.wakeup", "cron.fire"] do
      {:ok, signal} =
        accept_signal(%{
          target: %{agent_uid: agent.uid, session_id: "#{type}-#{Ecto.UUID.generate()}"},
          source: "test:schedule",
          subject: type,
          id: "event-#{Ecto.UUID.generate()}",
          type: type,
          available_at: now,
          sender: "schedule",
          data: %{}
        })

      assert {:ok, conversation} =
               Repo.transact(fn repo ->
                 ModelHistory.ensure_and_lock_conversation_in_tx(
                   repo,
                   agent.uid,
                   signal.session_id,
                   signal
                 )
               end)

      refute Map.has_key?(conversation.metadata, "origin")
    end
  end

  test "a reply route to an absent public conversation is rejected at acceptance" do
    %{principal: agent} = agent_fixture()

    assert {:error, %Ecto.Changeset{errors: errors}} =
             accept_signal(%{
               target: %{agent_uid: agent.uid, session_id: "missing-ingress"},
               source: "test:im",
               reply_route: %{binding_name: "test", conversation_id: Ecto.UUID.generate()},
               id: Ecto.UUID.generate(),
               type: "conversation.message.addressed",
               data: %{}
             })

    assert Keyword.has_key?(errors, :conversation_id)
  end

  defp accept_signal(attrs),
    do: Repo.transact(&Signals.accept_in_tx(&1, Map.put_new(attrs, :producer, :kernel)))

  defp record_tool_results(attrs) do
    {:ok, result} =
      Repo.transact(fn repo ->
        {:ok, Ankole.AIGateway.ToolResultJournal.record_tool_results_in_tx(repo, attrs)}
      end)

    case result do
      {:ok, message, _disposition} -> {:ok, message}
      error -> error
    end
  end

  defp start_response(subject_uid, conversation_id, request_metadata) do
    start_response_run(%{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      metadata: %{"request_metadata" => request_metadata}
    })
  end
end
