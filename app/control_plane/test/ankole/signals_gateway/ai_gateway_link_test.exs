defmodule Ankole.SignalsGateway.AIGatewayLinkTest do
  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.AIGateway.ResponseChain
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.Channel

  test "exact turn ownership rejects a composite turn" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "composite-replay")

    {:ok, response} =
      start_response(subject.uid, conversation.id, %{
        "actor_event_id" => "event-main",
        "request_refs" => [%{"actor_event_id" => "event-steer"}]
      })

    assert {:ok, _completed} =
             ResponseCommit.commit_complete(response, [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => "done"}]
               }
             ])

    actor_key = %{agent_uid: subject.uid, session_id: conversation.conversation_key}

    assert {:ok, :checked} =
             Repo.transact(fn repo ->
               refute AIGatewayLink.exact_turn_retryable_in_tx(repo, actor_key, "event-main")
               refute AIGatewayLink.exact_turn_retryable_in_tx(repo, actor_key, "event-steer")
               {:ok, :checked}
             end)
  end

  test "retracts only the current actor-correlated visible suffix" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-retry-retract")

    {:ok, predecessor} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-before"})

    {:ok, predecessor} = ResponseCommit.commit_complete(predecessor, [])

    {:ok, first} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{predecessor.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, first} = ResponseCommit.commit_complete(first, [])

    {:ok, second} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-retry"}}
      })

    {:ok, second} = ResponseCommit.commit_complete(second, [])

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
    assert ResponseChain.latest_visible_leaf(conversation.id) == predecessor.id
  end

  test "selects an actor-correlated visible suffix before calling generic deletion" do
    %{principal: subject} = agent_fixture()
    {:ok, conversation} = Conversations.ensure_conversation(subject.uid, "link-retraction")

    {:ok, first} =
      start_response(subject.uid, conversation.id, %{"actor_event_id" => "event-tail"})

    {:ok, first} = ResponseCommit.commit_complete(first, [])

    {:ok, second} =
      start_response_run(%{
        subject_uid: subject.uid,
        previous_response_id: "resp_#{first.id}",
        metadata: %{"request_metadata" => %{"actor_event_id" => "event-tail"}}
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

  test "declares a DM conversation origin from the mirrored channel" do
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
      SignalsGateway.append_actor_event(%{
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

    assert conversation.metadata["origin"] == %{
             "peer_uid" => peer.uid,
             "channel_id" => channel_id,
             "channel_kind" => "im_dm"
           }

    assert %{"origin" => successor_origin} =
             AIGatewayLink.successor_origin_metadata(conversation)

    assert successor_origin == conversation.metadata["origin"]
  end

  test "missing schedule delivery channels leave the conversation origin undeclared" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    for type <- ["check_back_later.wakeup", "cron.fire"] do
      {:ok, actor_event} =
        SignalsGateway.append_actor_event(%{
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

      refute Map.has_key?(conversation.metadata, "origin")
    end
  end

  test "missing ingress channels remain a hard conversation-origin error" do
    %{principal: agent} = agent_fixture()
    now = DateTime.utc_now(:microsecond)
    channel_id = "missing:ingress:channel"

    {:ok, actor_event} =
      SignalsGateway.append_actor_event(%{
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

    assert {:error, {:conversation_origin_channel_not_found, ^channel_id}} =
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
    start_response_run(%{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      metadata: %{"request_metadata" => request_metadata}
    })
  end
end
