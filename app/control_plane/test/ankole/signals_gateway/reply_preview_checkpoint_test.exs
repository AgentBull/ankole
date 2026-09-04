defmodule Ankole.SignalsGateway.ReplyPreviewCheckpointTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter
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
    stored_checkpoint = updated.reply_preview_checkpoint
    assert stored_checkpoint["schema_version"] == 2
    assert stored_checkpoint["streaming_state"] == "open"
    assert stored_checkpoint["adapter_state"]["card_id"] == "card-1"
    assert stored_checkpoint["adapter_state"]["message_id"] == "message-1"
    refute Map.has_key?(stored_checkpoint, "card_id")
    refute Map.has_key?(stored_checkpoint, "message_id")

    assert ReplyPreviewAdapter.adapter_checkpoint(stored_checkpoint)["card_id"] == "card-1"
    assert updated.reply_preview_cleanup_at == ~U[2026-07-14 02:40:00.000000Z]

    first_uuid = Ecto.UUID.generate()
    retry_uuid = Ecto.UUID.generate()

    assert {:ok,
            %{
              "sequence" => 1,
              "uuid" => ^first_uuid,
              "reused" => false,
              "sequence_current" => true
            }} =
             Actors.prepare_reply_preview_mutation(event.id, "working", "digest-1", first_uuid)

    assert {:ok,
            %{
              "sequence" => 1,
              "uuid" => ^first_uuid,
              "reused" => true,
              "sequence_current" => true
            }} =
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

  test "owner generation rejects a late working update after a card handoff" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: event} =
      emit_addressed_actor_event(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "owner-fence-event",
          signal_channel_id: "mock:owner-fence",
          source_entry_id: "source",
          explicit: true,
          text: "ping"
        })
      )

    continued = ReplyPresentation.new() |> ReplyPresentation.continued()

    assert {:ok, _event} =
             Actors.put_reply_preview_checkpoint(event.id, %{
               "presentation_owner" => false,
               "owner_generation" => 2,
               "stream_actor_event_id" => event.id,
               "presentation" => continued
             })

    assert {:error, :stale_reply_preview_owner_generation} =
             Actors.put_reply_preview_checkpoint(event.id, %{
               "presentation_owner" => true,
               "owner_generation" => 1,
               "presentation" => ReplyPresentation.new(state: "working")
             })

    assert {:error, :stale_reply_preview_owner} =
             Actors.put_reply_preview_checkpoint(event.id, %{
               "presentation" => ReplyPresentation.new(state: "working")
             })

    completed = ReplyPresentation.terminal(continued, "completed", "最终结果")

    assert {:ok, completed_event} =
             Actors.put_reply_preview_checkpoint(event.id, %{
               "owner_generation" => 2,
               "presentation_owner" => false,
               "presentation" => completed
             })

    assert completed_event.reply_preview_checkpoint["presentation"]["state"] == "completed"
  end

  test "dispatch can rebase an old continued owner onto its own new Turn stream" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: event} =
      emit_addressed_actor_event(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "owner-rebase-event",
          signal_channel_id: "mock:owner-rebase",
          source_entry_id: "source",
          explicit: true,
          text: "ping"
        })
      )

    assert {:ok, _event} =
             Actors.put_reply_preview_checkpoint(event.id, %{
               "presentation_owner" => false,
               "owner_generation" => 2,
               "stream_actor_event_id" => Ecto.UUID.generate(),
               "presentation" => ReplyPresentation.new() |> ReplyPresentation.continued()
             })

    assert {:ok, rebased_event} =
             Actors.put_reply_preview_checkpoint(event.id, %{
               "presentation_owner" => true,
               "owner_generation" => 3,
               "stream_actor_event_id" => event.id,
               "presentation" => ReplyPresentation.new(state: "working")
             })

    checkpoint = rebased_event.reply_preview_checkpoint
    assert checkpoint["presentation_owner"] == true
    assert checkpoint["owner_generation"] == 3
    assert checkpoint["stream_actor_event_id"] == event.id
    assert checkpoint["presentation"]["state"] == "working"
  end

  test "reads a flat legacy checkpoint and rewrites it with one replaceable adapter state" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{actor_event: event} =
      emit_addressed_actor_event(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "legacy-checkpoint-event",
          signal_channel_id: "mock:legacy-checkpoint",
          source_entry_id: "source",
          explicit: true,
          text: "ping"
        })
      )

    legacy = %{
      "schema_version" => 1,
      "adapter" => "slack",
      "message_id" => "message-old",
      "messages" => [%{"index" => 0, "message_id" => "message-old"}],
      "presentation" => ReplyPresentation.new(state: "working"),
      "streaming_state" => "open"
    }

    event =
      event
      |> ActorEvent.changeset(%{reply_preview_checkpoint: legacy})
      |> Repo.update!()

    assert ReplyPreviewAdapter.adapter_checkpoint(event.reply_preview_checkpoint)["message_id"] ==
             "message-old"

    replacement =
      legacy
      |> Map.delete("message_id")
      |> Map.put("messages", [%{"index" => 0, "message_id" => "message-new"}])

    assert {:ok, updated} = Actors.put_reply_preview_checkpoint(event.id, replacement)
    assert updated.reply_preview_checkpoint["schema_version"] == 2
    refute Map.has_key?(updated.reply_preview_checkpoint, "message_id")
    refute Map.has_key?(updated.reply_preview_checkpoint["adapter_state"], "message_id")

    assert updated.reply_preview_checkpoint["adapter_state"]["messages"] == [
             %{"index" => 0, "message_id" => "message-new"}
           ]
  end
end
