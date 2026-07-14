defmodule Ankole.SignalsGateway.ReplyPreviewCheckpointTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.RuntimeEvents

  test "persists a bounded card checkpoint and reuses one pending mutation identity" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: event} =
      emit_addressed_actor_event(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "checkpoint-event",
          signal_channel_id: "mock:checkpoint",
          source_entry_id: "source",
          explicit: true,
          text: "ping"
        })
      )

    checkpoint = %{
      "schema_version" => 1,
      "adapter" => "lark",
      "card_id" => "card-1",
      "message_id" => "message-1",
      "subject_uid" => subject.uid,
      "conversation_id" => Ecto.UUID.generate(),
      "streaming_state" => "open",
      "cleanup_at" => "2026-07-14T02:40:00.000000Z",
      "presentation" => %{"schema_version" => 1, "state" => "working", "answer" => "draft"}
    }

    assert {:ok, updated} = Actors.put_reply_preview_checkpoint(event.id, checkpoint)
    assert updated.reply_preview_checkpoint["card_id"] == "card-1"
    assert updated.reply_preview_cleanup_at == ~U[2026-07-14 02:40:00.000000Z]

    first_uuid = Ecto.UUID.generate()
    retry_uuid = Ecto.UUID.generate()

    assert {:ok, %{"sequence" => 1, "uuid" => ^first_uuid}} =
             Actors.prepare_reply_preview_mutation(event.id, "working", "digest-1", first_uuid)

    assert {:ok, %{"sequence" => 1, "uuid" => ^first_uuid}} =
             Actors.prepare_reply_preview_mutation(event.id, "working", "digest-1", retry_uuid)

    assert {:ok, %{"sequence" => 2}} =
             Actors.prepare_reply_preview_mutation(
               event.id,
               "working",
               "digest-2",
               Ecto.UUID.generate()
             )

    stored = Repo.get!(ActorEvent, event.id)
    assert stored.reply_preview_sequence_high_water == 2
    assert stored.reply_preview_checkpoint["sequence_high_water"] == 2

    channel = RuntimeEvents.reply_preview_checkpoint_channel()
    assert {^channel, payload} = Actors.reply_preview_runtime_event(stored)

    assert payload["actor_event_id"] == event.id

    cleanup_channel = RuntimeEvents.reply_preview_cleanup_channel()

    assert {^cleanup_channel, cleanup_payload} =
             Actors.reply_preview_cleanup_runtime_event(stored)

    assert cleanup_payload["due_at"] == "2026-07-14T02:40:00.000000Z"
  end
end
