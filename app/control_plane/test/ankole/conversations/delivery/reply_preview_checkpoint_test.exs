defmodule Ankole.Conversations.Delivery.ReplyPreviewCheckpointTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter

  test "owner claims check the Session fence before replacing the generation" do
    %{subject: subject, current: current, opts: opts} = owner_signals("claim-owner")

    assert {:ok, owner} =
             PreviewStates.claim_owner(
               current.id,
               subject.uid,
               opts[:conversation_id],
               current.id
             )

    assert PreviewStates.owner_generation(owner) == 1
    refute Map.has_key?(PreviewStates.get(owner).checkpoint, "presentation")

    stale_run = %{
      agent_uid: subject.uid,
      session_id: current.session_id,
      signal_id: current.id,
      epoch: -1
    }

    assert {:error, :stale_driver} = PreviewStates.authorize_owner(run: stale_run)

    assert {:error, :stale_driver} =
             PreviewStates.claim_owner(
               current.id,
               subject.uid,
               opts[:conversation_id],
               current.id,
               run: stale_run
             )

    assert PreviewStates.owner_generation(PreviewStates.load_signal(current.id)) == 1

    assert {:ok, replacement} =
             PreviewStates.claim_owner(
               current.id,
               subject.uid,
               opts[:conversation_id],
               current.id
             )

    assert PreviewStates.owner_generation(replacement) == 2
  end

  test "a handoff freezes visible content and advances beyond both stored generations" do
    %{subject: subject, current: current, next: next, opts: opts} = owner_signals("owner-handoff")

    assert {:ok, owner} =
             PreviewStates.claim_owner(
               current.id,
               subject.uid,
               opts[:conversation_id],
               current.id
             )

    assert {:ok, _next} =
             PreviewStates.put_checkpoint(next.id, %{
               "owner_generation" => 7,
               "continued_to_signal_id" => Ecto.UUID.generate()
             })

    presentation =
      ReplyPresentation.new(state: "working")
      |> Map.put("answer", "The visible answer")
      |> Map.put("thought", "Transient reasoning")

    assert {:ok, %{old_owner: previous, new_owner: adopted}} =
             PreviewStates.switch_owner(
               owner,
               next,
               1,
               presentation,
               opts ++ [visible?: true, refresh?: true]
             )

    previous_checkpoint = PreviewStates.get(previous).checkpoint
    assert previous_checkpoint["presentation_owner"] == false
    assert previous_checkpoint["continued_to_signal_id"] == next.id
    assert previous_checkpoint["presentation"]["state"] == "continued"
    assert previous_checkpoint["presentation"]["answer"] == "The visible answer"
    refute Map.has_key?(previous_checkpoint["presentation"], "thought")
    assert previous_checkpoint["refresh_pending"] == true
    assert previous_checkpoint["refresh_reason"] == "owner_handoff"

    adopted_checkpoint = PreviewStates.get(adopted).checkpoint
    assert PreviewStates.owner_generation(adopted) == 8
    assert adopted_checkpoint["presentation_owner"] == true
    refute Map.has_key?(adopted_checkpoint, "continued_to_signal_id")
    assert adopted_checkpoint["stream_signal_id"] == current.id
    assert adopted_checkpoint["subject_uid"] == subject.uid
    assert adopted_checkpoint["conversation_id"] == opts[:conversation_id]
    assert adopted_checkpoint["presentation"]["state"] == "working"
    assert PreviewStates.current_presentation_owner(current.id, next).id == next.id
  end

  test "an invisible handoff records no continued presentation and rolls back a rejected transfer" do
    %{subject: subject, current: current, next: next, opts: opts} = owner_signals("empty-handoff")

    assert {:ok, owner} =
             PreviewStates.claim_owner(
               current.id,
               subject.uid,
               opts[:conversation_id],
               current.id
             )

    # A transferred target cannot be revived by another stream. Its rejection
    # occurs after the old owner's proposed update, so both writes must roll back.
    assert {:ok, _next} =
             PreviewStates.put_checkpoint(next.id, %{
               "owner_generation" => 3,
               "presentation_owner" => false,
               "stream_signal_id" => current.id
             })

    assert {:error, :stale_reply_preview_owner} =
             PreviewStates.switch_owner(
               owner,
               next,
               1,
               ReplyPresentation.new(),
               opts ++ [visible?: false, refresh?: false]
             )

    unchanged = PreviewStates.load_signal(current.id)
    assert PreviewStates.get(unchanged).checkpoint == PreviewStates.get(owner).checkpoint

    assert {:ok, replacement} =
             PreviewStates.claim_owner(next.id, subject.uid, opts[:conversation_id], next.id)

    assert {:ok, %{old_owner: previous, new_owner: adopted}} =
             PreviewStates.switch_owner(
               owner,
               replacement,
               1,
               ReplyPresentation.new(),
               opts ++ [visible?: false, refresh?: false]
             )

    previous_checkpoint = PreviewStates.get(previous).checkpoint
    assert previous_checkpoint["presentation_owner"] == false
    refute Map.has_key?(previous_checkpoint, "presentation")
    assert PreviewStates.owner_generation(adopted) == 5
  end

  test "presentation checkpoints keep newer durable revisions and reject a replaced owner" do
    %{subject: subject, current: current, opts: opts} = owner_signals("presentation-order")

    assert {:ok, _owner} =
             PreviewStates.claim_owner(
               current.id,
               subject.uid,
               opts[:conversation_id],
               current.id
             )

    presentation =
      ReplyPresentation.new(state: "working")
      |> Map.put("revision", 2)
      |> Map.put("answer", "Committed content")

    assert {:ok, stored} =
             PreviewStates.checkpoint_presentation(current.id, 1, presentation, opts)

    checkpoint = PreviewStates.get(stored).checkpoint

    assert {:ok, unchanged} =
             PreviewStates.checkpoint_presentation(
               current.id,
               1,
               Map.put(presentation, "answer", "Equal revision"),
               opts
             )

    assert PreviewStates.get(unchanged).checkpoint == checkpoint

    assert {:ok, replacement} =
             PreviewStates.claim_owner(
               current.id,
               subject.uid,
               opts[:conversation_id],
               current.id
             )

    newer = presentation |> Map.put("revision", 3) |> Map.put("answer", "New content")
    assert {:ok, unchanged} = PreviewStates.checkpoint_presentation(current.id, 1, newer, opts)
    assert PreviewStates.get(unchanged).checkpoint == PreviewStates.get(replacement).checkpoint

    assert {:ok, updated} = PreviewStates.checkpoint_presentation(current.id, 2, newer, opts)
    assert PreviewStates.get(updated).checkpoint["presentation"]["answer"] == "New content"
  end

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
             PreviewStates.put_checkpoint(event.id, checkpoint)

    stored_checkpoint = Ankole.Conversations.Delivery.PreviewStates.get(updated).checkpoint
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
             PreviewStates.prepare_mutation(
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
             PreviewStates.prepare_mutation(
               event.id,
               "working",
               "digest-1",
               retry_uuid
             )

    assert {:ok, %{"sequence" => 2}} =
             PreviewStates.prepare_mutation(
               event.id,
               "working",
               "digest-2",
               Ecto.UUID.generate()
             )

    stored = Repo.get!(Signal, event.id)
    assert Ankole.Conversations.Delivery.PreviewStates.get(stored).sequence_high_water == 2

    assert Ankole.Conversations.Delivery.PreviewStates.get(stored).checkpoint[
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
             PreviewStates.put_checkpoint(event.id, %{
               "owner_generation" => 2,
               "stream_signal_id" => event.id,
               "presentation_owner" => false,
               "presentation" => ReplyPresentation.new()
             })

    stored = Repo.get!(Signal, event.id)

    assert {:error, :stale_reply_preview_owner_generation} =
             PreviewStates.put_checkpoint(
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
    assert Ankole.Conversations.Delivery.PreviewStates.get(current).provider_message_id == nil
    assert current.provider_thread_id == stored.provider_thread_id

    assert Ankole.Conversations.Delivery.PreviewStates.get(current).checkpoint ==
             Ankole.Conversations.Delivery.PreviewStates.get(stored).checkpoint
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
             PreviewStates.put_checkpoint(event.id, %{
               "presentation_owner" => false,
               "owner_generation" => 2,
               "stream_signal_id" => event.id,
               "presentation" => continued
             })

    assert {:error, :stale_reply_preview_owner_generation} =
             PreviewStates.put_checkpoint(event.id, %{
               "presentation_owner" => true,
               "owner_generation" => 1,
               "presentation" => ReplyPresentation.new(state: "working")
             })

    assert {:error, :stale_reply_preview_owner} =
             PreviewStates.put_checkpoint(event.id, %{
               "presentation" => ReplyPresentation.new(state: "working")
             })

    completed = ReplyPresentation.terminal(continued, "completed", "最终结果")

    assert {:ok, completed_event} =
             PreviewStates.put_checkpoint(event.id, %{
               "owner_generation" => 2,
               "presentation_owner" => false,
               "presentation" => completed
             })

    assert Ankole.Conversations.Delivery.PreviewStates.get(completed_event).checkpoint[
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
             PreviewStates.put_checkpoint(event.id, %{
               "presentation_owner" => false,
               "owner_generation" => 2,
               "stream_signal_id" => Ecto.UUID.generate(),
               "presentation" => ReplyPresentation.new() |> ReplyPresentation.continued()
             })

    assert {:ok, rebased_event} =
             PreviewStates.put_checkpoint(event.id, %{
               "presentation_owner" => true,
               "owner_generation" => 3,
               "stream_signal_id" => event.id,
               "presentation" => ReplyPresentation.new(state: "working")
             })

    checkpoint = Ankole.Conversations.Delivery.PreviewStates.get(rebased_event).checkpoint
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
             Ankole.Conversations.Delivery.PreviewStates.get(event).checkpoint
           )["message_id"] ==
             "message-old"

    replacement =
      legacy
      |> Map.delete("message_id")
      |> Map.put("messages", [%{"index" => 0, "message_id" => "message-new"}])

    assert {:ok, updated} =
             PreviewStates.put_checkpoint(event.id, replacement)

    assert Ankole.Conversations.Delivery.PreviewStates.get(updated).checkpoint["schema_version"] ==
             2

    refute Map.has_key?(
             Ankole.Conversations.Delivery.PreviewStates.get(updated).checkpoint,
             "message_id"
           )

    refute Map.has_key?(
             Ankole.Conversations.Delivery.PreviewStates.get(updated).checkpoint["adapter_state"],
             "message_id"
           )

    assert Ankole.Conversations.Delivery.PreviewStates.get(updated).checkpoint["adapter_state"][
             "messages"
           ] == [
             %{"index" => 0, "message_id" => "message-new"}
           ]
  end

  defp owner_signals(prefix) do
    %{principal: subject} = agent_fixture()
    binding_fixture(subject.uid, "mock", :ignore, adapter: "mock-provider")

    [current, next] =
      Enum.map(["current", "next"], fn suffix ->
        %{signal: signal} =
          emit_addressed_signal(
            subject.uid,
            "mock",
            group_entry(%{
              source_event_id: prefix <> ":" <> suffix,
              provider_conversation_id: "mock:" <> prefix,
              provider_message_id: prefix <> ":" <> suffix,
              explicit: true,
              text: "Reply to this input"
            })
          )

        signal
      end)

    %{
      subject: subject,
      current: current,
      next: next,
      opts: [
        subject_uid: subject.uid,
        conversation_id: Ecto.UUID.generate(),
        stream_signal_id: current.id
      ]
    }
  end
end
