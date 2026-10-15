defmodule Ankole.Conversations.Delivery.ReplyPreviewCheckpointTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter

  test "persists a bounded card checkpoint and reuses one pending mutation identity" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: event} =
      emit_addressed_signal(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "checkpoint-event",
          conversation_id: "mock:checkpoint",
          provider_message_id: "source",
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

    assert {:ok, updated} =
             PreviewState.put_checkpoint(event.id, checkpoint)

    stored_checkpoint = Ankole.Conversations.Delivery.PreviewState.get(updated).checkpoint
    assert stored_checkpoint["schema_version"] == 2
    assert stored_checkpoint["streaming_state"] == "open"
    assert stored_checkpoint["adapter_state"]["card_id"] == "card-1"
    assert stored_checkpoint["adapter_state"]["message_id"] == "message-1"
    refute Map.has_key?(stored_checkpoint, "card_id")
    refute Map.has_key?(stored_checkpoint, "message_id")

    assert PreviewAdapter.adapter_checkpoint(stored_checkpoint)["card_id"] == "card-1"

    assert_enqueued(
      worker: Ankole.Conversations.Delivery.Jobs.PreviewCleanup,
      args: %{signal_id: event.id, tenant_id: event.tenant_id},
      scheduled_at: ~U[2026-07-14 02:40:00.000000Z]
    )

    first_uuid = Ecto.UUID.generate()
    retry_uuid = Ecto.UUID.generate()

    assert {:ok,
            %{
              "sequence" => 1,
              "uuid" => ^first_uuid,
              "reused" => false,
              "sequence_current" => true
            }} =
             PreviewState.prepare_mutation(
               event.id,
               "working",
               "digest-1",
               first_uuid
             )

    assert {:ok,
            %{
              "sequence" => 1,
              "uuid" => ^first_uuid,
              "reused" => true,
              "sequence_current" => true
            }} =
             PreviewState.prepare_mutation(
               event.id,
               "working",
               "digest-1",
               retry_uuid
             )

    assert {:ok, %{"sequence" => 2}} =
             PreviewState.prepare_mutation(
               event.id,
               "working",
               "digest-2",
               Ecto.UUID.generate()
             )

    stored = Repo.get!(Signal, event.id)
    assert Ankole.Conversations.Delivery.PreviewState.get(stored).sequence_high_water == 2

    assert Ankole.Conversations.Delivery.PreviewState.get(stored).checkpoint[
             "sequence_high_water"
           ] == 2

    assert Repo.get_by!(Oban.Job,
             worker: "Ankole.Conversations.Delivery.Jobs.PreviewCheckpoint",
             args: %{"signal_id" => event.id, "tenant_id" => event.tenant_id}
           )

    cleanup =
      Repo.get_by!(Oban.Job,
        worker: "Ankole.Conversations.Delivery.Jobs.PreviewCleanup",
        args: %{"signal_id" => event.id, "tenant_id" => event.tenant_id}
      )

    assert cleanup.scheduled_at == ~U[2026-07-14 02:40:00.000000Z]
  end

  test "an old owner cannot checkpoint or record the first provider source" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: event} =
      emit_addressed_signal(subject.uid, "mock", group_entry(%{explicit: true}))

    assert {:ok, _} =
             PreviewState.put_checkpoint(event.id, %{
               "owner_generation" => 2,
               "stream_signal_id" => event.id,
               "presentation_owner" => false,
               "presentation" => ReplyPresentation.new()
             })

    stored = Repo.get!(Signal, event.id)

    assert {:error, :stale_reply_preview_owner_generation} =
             PreviewState.put_checkpoint(
               event.id,
               %{
                 "owner_generation" => 1,
                 "stream_signal_id" => event.id,
                 "presentation_owner" => true,
                 "message_id" => "stale-source",
                 "presentation" => ReplyPresentation.new()
               },
               {"stale-source", "stale-thread"}
             )

    current = Repo.get!(Signal, event.id)
    assert Ankole.Conversations.Delivery.PreviewState.get(current).provider_message_id == nil
    assert current.provider_thread_id == stored.provider_thread_id

    assert Ankole.Conversations.Delivery.PreviewState.get(current).checkpoint ==
             Ankole.Conversations.Delivery.PreviewState.get(stored).checkpoint
  end

  test "owner generation rejects a late working update after a card handoff" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: event} =
      emit_addressed_signal(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "owner-fence-event",
          conversation_id: "mock:owner-fence",
          provider_message_id: "source",
          explicit: true,
          text: "ping"
        })
      )

    continued = ReplyPresentation.new() |> ReplyPresentation.continued()

    assert {:ok, _event} =
             PreviewState.put_checkpoint(event.id, %{
               "presentation_owner" => false,
               "owner_generation" => 2,
               "stream_signal_id" => event.id,
               "presentation" => continued
             })

    assert {:error, :stale_reply_preview_owner_generation} =
             PreviewState.put_checkpoint(event.id, %{
               "presentation_owner" => true,
               "owner_generation" => 1,
               "presentation" => ReplyPresentation.new(state: "working")
             })

    assert {:error, :stale_reply_preview_owner} =
             PreviewState.put_checkpoint(event.id, %{
               "presentation" => ReplyPresentation.new(state: "working")
             })

    completed = ReplyPresentation.terminal(continued, "completed", "最终结果")

    assert {:ok, completed_event} =
             PreviewState.put_checkpoint(event.id, %{
               "owner_generation" => 2,
               "presentation_owner" => false,
               "presentation" => completed
             })

    assert Ankole.Conversations.Delivery.PreviewState.get(completed_event).checkpoint[
             "presentation"
           ]["state"] == "completed"
  end

  test "dispatch can rebase an old continued owner onto its own new Turn stream" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: event} =
      emit_addressed_signal(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "owner-rebase-event",
          conversation_id: "mock:owner-rebase",
          provider_message_id: "source",
          explicit: true,
          text: "ping"
        })
      )

    assert {:ok, _event} =
             PreviewState.put_checkpoint(event.id, %{
               "presentation_owner" => false,
               "owner_generation" => 2,
               "stream_signal_id" => Ecto.UUID.generate(),
               "presentation" => ReplyPresentation.new() |> ReplyPresentation.continued()
             })

    assert {:ok, rebased_event} =
             PreviewState.put_checkpoint(event.id, %{
               "presentation_owner" => true,
               "owner_generation" => 3,
               "stream_signal_id" => event.id,
               "presentation" => ReplyPresentation.new(state: "working")
             })

    checkpoint = Ankole.Conversations.Delivery.PreviewState.get(rebased_event).checkpoint
    assert checkpoint["presentation_owner"] == true
    assert checkpoint["owner_generation"] == 3
    assert checkpoint["stream_signal_id"] == event.id
    assert checkpoint["presentation"]["state"] == "working"
  end

  test "reads a flat legacy checkpoint and rewrites it with one replaceable adapter state" do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    %{signal: event} =
      emit_addressed_signal(
        subject.uid,
        "mock",
        group_entry(%{
          source_event_id: "legacy-checkpoint-event",
          conversation_id: "mock:legacy-checkpoint",
          provider_message_id: "source",
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
      |> Ankole.PreviewFixtures.update!(%{checkpoint: legacy})

    assert PreviewAdapter.adapter_checkpoint(
             Ankole.Conversations.Delivery.PreviewState.get(event).checkpoint
           )["message_id"] ==
             "message-old"

    replacement =
      legacy
      |> Map.delete("message_id")
      |> Map.put("messages", [%{"index" => 0, "message_id" => "message-new"}])

    assert {:ok, updated} =
             PreviewState.put_checkpoint(event.id, replacement)

    assert Ankole.Conversations.Delivery.PreviewState.get(updated).checkpoint["schema_version"] ==
             2

    refute Map.has_key?(
             Ankole.Conversations.Delivery.PreviewState.get(updated).checkpoint,
             "message_id"
           )

    refute Map.has_key?(
             Ankole.Conversations.Delivery.PreviewState.get(updated).checkpoint["adapter_state"],
             "message_id"
           )

    assert Ankole.Conversations.Delivery.PreviewState.get(updated).checkpoint["adapter_state"][
             "messages"
           ] == [
             %{"index" => 0, "message_id" => "message-new"}
           ]
  end
end
