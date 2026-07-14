defmodule Ankole.SignalsGateway.AIGatewayLinkTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.Channel

  test "selects and fails only the explicit actor-correlated generating Response" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-cancel")

    {:ok, selected} =
      start_response(subject.uid, conversation.id, %{
        "actor_event_id" => "event-selected",
        "request_refs" => [%{"actor_event_id" => "event-steer"}]
      })

    {:ok, untouched} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-other"})

    actor_key = %{agent_uid: subject.uid, session_id: conversation.conversation_key}
    now = DateTime.utc_now(:microsecond)

    assert {:ok, failed} =
             Repo.transact(fn repo ->
               assert %{
                        response_id: response_id,
                        actor_event_id: "event-selected",
                        request_ref_actor_event_ids: ["event-steer"]
                      } = AIGatewayLink.generating_turn_in_tx(repo, actor_key, "event-selected")

               assert response_id == "resp_#{selected.id}"

               AIGatewayLink.cancel_generating_turn_in_tx(
                 repo,
                 actor_key,
                 "event-selected",
                 now,
                 "command.stop"
               )
             end)

    assert failed.id == selected.id
    assert failed.status == "error"
    assert failed.metadata["error"]["code"] == "command.stop"
    assert Repo.get!(Message, untouched.id).status == "generating"
  end

  test "finds retry source from opaque request metadata and user input" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-retry")

    {:ok, response} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "retry me"}]
          }
        ],
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, response} = StatefulResponses.commit_complete(response, [])

    assert {:ok,
            %{
              actor_event_id: "event-retry",
              message_id: message_id,
              status: "complete",
              text: "retry me"
            }} =
             Repo.transact(fn repo ->
               AIGatewayLink.retry_source_in_tx(
                 repo,
                 subject.uid,
                 conversation.conversation_key
               )
             end)

    assert message_id == response.id
  end

  test "retracts only the current actor-correlated visible suffix" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-retry-retract")

    {:ok, predecessor} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-before"})

    {:ok, predecessor} = StatefulResponses.commit_complete(predecessor, [])

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{predecessor.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, first} = StatefulResponses.commit_complete(first, [])

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, second} = StatefulResponses.commit_complete(second, [])

    assert {:ok, %{status: :retracted, retracted_count: 2}} =
             Repo.transact(fn repo ->
               AIGatewayLink.retract_visible_turn_suffix_in_tx(
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
    assert StatefulResponses.latest_visible_leaf(conversation.id) == predecessor.id
  end

  test "reads the exact system prompt from the conversation's first provider run" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-system-prompt")

    {:ok, first} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        conversation_id: conversation.id,
        metadata: %{"instructions" => "first prompt\nkept byte-for-byte"}
      })

    {:ok, first} = StatefulResponses.commit_complete(first, [])

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"instructions" => "later rebuilt prompt"}
      })

    {:ok, _second} = StatefulResponses.commit_complete(second, [])

    assert AIGatewayLink.system_prompt_snapshot(conversation) ==
             "first prompt\nkept byte-for-byte"
  end

  test "selects an actor-correlated visible suffix before calling generic deletion" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject.uid, "link-retraction")

    {:ok, first} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-tail"})

    {:ok, first} = StatefulResponses.commit_complete(first, [])

    {:ok, second} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-tail"}}
      })

    {:ok, second} = StatefulResponses.commit_complete(second, [])

    assert {:ok,
            %{
              status: :deleted,
              deleted_count: 2,
              failed_generating_count: 0,
              deleted_message_ids: deleted_ids
            }} =
             Repo.transact(fn repo ->
               AIGatewayLink.delete_visible_turn_suffix_in_tx(
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

  test "declares and freezes a DM Brain scope from the mirrored channel" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()
    now = DateTime.utc_now(:microsecond)
    channel_id = "dm:#{Ecto.UUID.generate()}"

    Repo.insert!(%Channel{
      id: channel_id,
      kind: :im_dm,
      reply_mode: :entry,
      metadata: %{"dm_peer_principal_uid" => peer.uid},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })

    {:ok, actor_event} =
      Actors.append_actor_event(%{
        agent_uid: agent.uid,
        binding_name: "test",
        session_id: "dm-session",
        source_event_id: "event-#{Ecto.UUID.generate()}",
        signal_channel_id: channel_id,
        source_entry_id: "message-1",
        type: "im.message.addressed",
        available_at: now,
        sender_key: peer.uid,
        payload: %{"data" => %{"entry" => %{"author" => %{"principal_uid" => peer.uid}}}}
      })

    assert {:ok, conversation} =
             Repo.transact(fn repo ->
               AIGatewayLink.ensure_and_lock_conversation_in_tx(
                 repo,
                 agent.uid,
                 actor_event.session_id,
                 actor_event
               )
             end)

    assert conversation.metadata["brain"] == %{
             "visibility" => "dm",
             "peer_uid" => peer.uid,
             "channel_id" => channel_id,
             "channel_kind" => "im_dm"
           }

    conversation = %{
      conversation
      | metadata: put_in(conversation.metadata, ["brain", "snapshot"], %{"pinned_memo" => "old"})
    }

    assert %{"brain" => successor_scope} =
             AIGatewayLink.successor_brain_metadata(conversation)

    refute Map.has_key?(successor_scope, "snapshot")
    assert successor_scope["peer_uid"] == peer.uid
  end

  test "missing schedule delivery channels use the principal public Brain scope" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    for type <- ["check_back_later.wakeup", "cron.fire"] do
      {:ok, actor_event} =
        Actors.append_actor_event(%{
          agent_uid: agent.uid,
          binding_name: "schedule",
          session_id: "#{type}-#{Ecto.UUID.generate()}",
          source_event_id: "event-#{Ecto.UUID.generate()}",
          signal_channel_id: "missing:schedule:channel",
          source_entry_id: "schedule-#{Ecto.UUID.generate()}",
          type: type,
          available_at: now,
          sender_key: "schedule",
          payload: %{}
        })

      assert {:ok, conversation} =
               Repo.transact(fn repo ->
                 AIGatewayLink.ensure_and_lock_conversation_in_tx(
                   repo,
                   agent.uid,
                   actor_event.session_id,
                   actor_event
                 )
               end)

      assert conversation.metadata["brain"] == %{"visibility" => "public"}
    end
  end

  test "missing ingress channels remain a hard Brain scope error" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)
    channel_id = "missing:ingress:channel"

    {:ok, actor_event} =
      Actors.append_actor_event(%{
        agent_uid: agent.uid,
        binding_name: "test",
        session_id: "missing-ingress-channel",
        source_event_id: "event-#{Ecto.UUID.generate()}",
        signal_channel_id: channel_id,
        source_entry_id: "message-#{Ecto.UUID.generate()}",
        type: "im.message.addressed",
        available_at: now,
        sender_key: "human-one",
        payload: %{}
      })

    assert {:error, {:brain_scope_channel_not_found, ^channel_id}} =
             Repo.transact(fn repo ->
               AIGatewayLink.ensure_and_lock_conversation_in_tx(
                 repo,
                 agent.uid,
                 actor_event.session_id,
                 actor_event
               )
             end)
  end

  defp start_response(subject_uid, conversation_id, request_metadata) do
    StatefulResponses.start_response_run(%{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      metadata: %{"request_metadata" => request_metadata}
    })
  end
end
