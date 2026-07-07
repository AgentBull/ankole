defmodule Ankole.E2E.WaitHelpersTest do
  use Ankole.ActorRuntimeCase

  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.E2E.WaitHelpers
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.OutboxEntry

  setup {Ankole.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  test "completed final reply waits for the latest final message mirror" do
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    %{actor_event: actor_event} =
      Ankole.SignalsGatewayFixtures.emit_addressed_actor_event(
        agent.uid,
        "mock",
        Ankole.SignalsGatewayFixtures.group_entry(%{
          source_event_id: "wait-helper-latest-final",
          signal_channel_id: "mock:chat:wait-helper-latest-final",
          source_entry_id: "human-wait-helper-latest-final",
          explicit: true,
          text: "Need a final reply."
        })
      )

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    old_message =
      insert_message!(agent.uid, conversation.id, actor_event.id, "old final", nil)

    latest_message =
      insert_message!(agent.uid, conversation.id, actor_event.id, "latest final", old_message.id)

    actor_event
    |> ActorEvent.changeset(%{completed_at: DateTime.utc_now(:microsecond)})
    |> Repo.update!()

    latest_mirror = insert_mirror!(actor_event, latest_message, "latest-final-mirror")
    old_mirror = insert_mirror!(actor_event, old_message, "old-final-mirror")

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
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    %{actor_event: actor_event} =
      Ankole.SignalsGatewayFixtures.emit_addressed_actor_event(
        agent.uid,
        "mock",
        Ankole.SignalsGatewayFixtures.group_entry(%{
          source_event_id: "wait-helper-runtime-event-final",
          signal_channel_id: "mock:chat:wait-helper-runtime-event-final",
          source_entry_id: "human-wait-helper-runtime-event-final",
          explicit: true,
          text: "Need a dispatched final reply."
        })
      )

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)

    {:ok, run} =
      StatefulResponses.start_response_run(%{
        agent_uid: agent.uid,
        conversation_id: conversation.id,
        actor_event_id: actor_event.id
      })

    assert {:ok, committed} =
             StatefulResponses.commit_complete(run, assistant_content("runtime event final"))

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
    %{principal: agent} = agent_fixture()

    Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "mock", :ignore,
      adapter: "mock-provider"
    )

    %{actor_event: actor_event} =
      Ankole.SignalsGatewayFixtures.emit_addressed_actor_event(
        agent.uid,
        "mock",
        Ankole.SignalsGatewayFixtures.group_entry(%{
          source_event_id: "wait-helper-multiple-side-effects",
          signal_channel_id: "mock:chat:wait-helper-multiple-side-effects",
          source_entry_id: "human-wait-helper-multiple-side-effects",
          explicit: true,
          text: "Need multiple side effects."
        })
      )

    {:ok, conversation} = StatefulResponses.ensure_conversation(agent.uid, actor_event.session_id)
    message = insert_message!(agent.uid, conversation.id, actor_event.id, "done", nil)

    actor_event
    |> ActorEvent.changeset(%{completed_at: DateTime.utc_now(:microsecond)})
    |> Repo.update!()

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

  defp assistant_content(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp insert_message!(agent_uid, conversation_id, actor_event_id, text, previous_message_id) do
    %Message{}
    |> Message.changeset(%{
      agent_uid: agent_uid,
      conversation_id: conversation_id,
      previous_message_id: previous_message_id,
      role: "assistant",
      type: "message",
      status: "complete",
      content: [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ],
      metadata: %{"actor_event_id" => actor_event_id}
    })
    |> Repo.insert!()
  end

  defp insert_mirror!(actor_event, message, source_entry_id) do
    now = DateTime.utc_now(:microsecond)

    %Entry{}
    |> Entry.changeset(%{
      signal_channel_id: actor_event.signal_channel_id,
      source_entry_id: source_entry_id,
      text: source_entry_id,
      formatted_content: %{},
      attachments: [],
      links: [],
      author: %{"agent_uid" => actor_event.agent_uid},
      mentions: [],
      metadata: %{
        "actor_event_id" => actor_event.id,
        "ai_message_id" => message.id
      },
      raw_payload: %{},
      provider_time: now,
      fallback_visible_text: source_entry_id,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: "doc-#{source_entry_id}",
      search_text: source_entry_id,
      metadata_text: "",
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
