defmodule Ankole.E2E.WaitHelpersTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.E2E.WaitHelpers
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.OutboxEntry

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  test "completed final reply waits for the latest final message mirror" do
    %{agent: agent, actor_event: actor_event, turn_ref: turn_ref} =
      start_accepted_turn("latest-final", "Need a final reply.")

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    old_message = complete_response!(agent.uid, conversation.id, actor_event.id, "old final")

    latest_message =
      complete_response!(
        agent.uid,
        conversation.id,
        actor_event.id,
        "latest final",
        "resp_#{old_message.id}"
      )

    assert {:ok, %{status: :turn_completed}} = complete_turn(turn_ref, latest_message)

    latest_mirror = insert_mirror!(actor_event, latest_message, "latest-final-mirror")
    old_mirror = insert_mirror!(actor_event, old_message, "old-final-mirror")

    _attachment_mirror =
      insert_mirror!(actor_event, latest_message, "latest-attachment-mirror", %{})

    force_inserted_at!(old_mirror, DateTime.add(latest_mirror.inserted_at, 1, :second))

    assert {:ok, %Entry{} = reply, %Message{} = message} =
             WaitHelpers.wait_for_completed_final_reply(
               %{},
               actor_event.id,
               WaitHelpers.deadline(1_000)
             )

    assert reply.ai_message_id == latest_message.id
    assert message.id == latest_message.id
  end

  test "completed final reply advances due outbox runtime events from the durable snapshot" do
    %{agent: agent, actor_event: actor_event, turn_ref: turn_ref} =
      start_accepted_turn("runtime-event-final", "Need a dispatched final reply.")

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    committed =
      complete_response!(agent.uid, conversation.id, actor_event.id, "runtime event final")

    assert {:ok, %{status: :turn_completed}} = complete_turn(turn_ref, committed)

    assert %OutboxEntry{status: :created} =
             Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{committed.id}")

    port = open_idle_port!()

    assert {:ok, %Entry{} = reply, %Message{} = message} =
             WaitHelpers.wait_for_completed_final_reply(
               port,
               actor_event.id,
               WaitHelpers.deadline(1_000)
             )

    assert reply.ai_message_id == committed.id
    assert message.id == committed.id
  end

  test "completed outbox helper fails loudly when one input produced multiple side-effect rows" do
    %{agent: agent, actor_event: actor_event, turn_ref: turn_ref} =
      start_accepted_turn("multiple-side-effects", "Need multiple side effects.")

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)
    message = complete_response!(agent.uid, conversation.id, actor_event.id, "done")

    assert {:ok, %{status: :turn_completed}} = complete_turn(turn_ref, message)

    insert_side_effect_outbox!(actor_event, message, "side-effect:one")
    insert_side_effect_outbox!(actor_event, message, "side-effect:two")

    assert_raise ExUnit.AssertionError, ~r/expected one side-effect outbox/, fn ->
      WaitHelpers.wait_for_outbox_for_input(
        %{},
        actor_event.id,
        WaitHelpers.deadline(1_000),
        message.id
      )
    end
  end

  defp start_accepted_turn(suffix, text) do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    %{actor_event: actor_event} =
      Ankole.SignalsGatewayFixtures.emit_addressed_actor_event(
        agent.uid,
        "mock",
        Ankole.SignalsGatewayFixtures.group_entry(%{
          source_event_id: "wait-helper-#{suffix}",
          signal_channel_id: "mock:chat:wait-helper-#{suffix}",
          source_entry_id: "human-wait-helper-#{suffix}",
          explicit: true,
          text: text
        })
      )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}, 2_000
    turn_ref = envelope["body"]["turn_start"]["turn"]

    assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{"turn" => turn_ref}
             })

    %{agent: agent, actor_event: actor_event, turn_ref: turn_ref}
  end

  defp assistant_content(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp complete_response!(subject_uid, conversation_id, actor_event_id, text) do
    complete_response!(subject_uid, conversation_id, actor_event_id, text, nil)
  end

  defp complete_response!(subject_uid, conversation_id, actor_event_id, text, previous) do
    attrs = %{
      subject_uid: subject_uid,
      metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}}
    }

    attrs =
      case previous do
        nil -> Map.put(attrs, :conversation_id, conversation_id)
        previous_response_id -> Map.put(attrs, :previous_response_id, previous_response_id)
      end

    assert {:ok, run} = StatefulResponses.start_response_run(attrs)
    assert {:ok, response} = StatefulResponses.commit_complete(run, assistant_content(text))
    response
  end

  defp complete_turn(turn_ref, response) do
    ActorRuntime.handle_turn_completed(%{
      "turn_completed" => %{
        "turn" => turn_ref,
        "final_response_id" => "resp_#{response.id}",
        "outcome" => "loop_finished"
      }
    })
  end

  defp insert_mirror!(actor_event, message, source_entry_id, metadata \\ nil) do
    now = DateTime.utc_now(:microsecond)

    metadata =
      metadata ||
        %{
          "actor_event_id" => actor_event.id,
          "ai_message_id" => message.id
        }

    %Entry{}
    |> Entry.changeset(%{
      signal_channel_id: actor_event.signal_channel_id,
      source_entry_id: source_entry_id,
      text: source_entry_id,
      attachments: [],
      links: [],
      author: %{"agent_uid" => actor_event.agent_uid},
      mentions: [],
      metadata: metadata,
      raw_payload: %{},
      provider_time: now,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: "doc-#{source_entry_id}",
      content_hash: "hash-#{source_entry_id}",
      first_seen_at: now,
      last_seen_at: now,
      ai_message_id: message.id
    })
    |> Repo.insert!()
  end

  defp insert_side_effect_outbox!(actor_event, message, outbound_key) do
    assert {:ok, %OutboxEntry{} = outbox} =
             SignalsGateway.commit_outbox(%{
               agent_uid: actor_event.agent_uid,
               binding_name: actor_event.binding_name,
               outbound_key: outbound_key,
               operation: :reply,
               signal_channel_id: actor_event.signal_channel_id,
               reply_to_source_entry_id: actor_event.source_entry_id,
               source_actor_event_id: actor_event.id,
               ai_message_id: message.id,
               payload: %{"text" => outbound_key},
               fallback_visible_text: outbound_key,
               idempotency_key: outbound_key
             })

    outbox
  end

  defp open_idle_port! do
    port = Port.open({:spawn, "cat"}, [:binary, :exit_status])

    on_exit(fn ->
      if Port.info(port) do
        Port.close(port)
      end
    end)

    port
  end

  defp force_inserted_at!(%Entry{} = mirror, inserted_at) do
    Entry
    |> where(
      [entry],
      entry.signal_channel_id == ^mirror.signal_channel_id and
        entry.source_entry_id == ^mirror.source_entry_id
    )
    |> Repo.update_all(set: [inserted_at: inserted_at])
  end
end
