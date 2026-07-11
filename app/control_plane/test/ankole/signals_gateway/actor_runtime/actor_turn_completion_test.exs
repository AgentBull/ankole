defmodule Ankole.SignalsGateway.ActorRuntime.ActorTurnCompletionTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.SignalsGateway.InputTombstone

  setup context do
    Ankole.SignalsGateway.ActorRuntimeCase.use_mock_signal_provider_plugin(context)
  end

  describe "turn_completed" do
    test "atomically commits a final reply and is idempotent after the Response disappears" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("completion")
      final = complete_response(agent.uid, event, "done")

      assert {:ok, %{status: :turn_completed, deleted_deliveries: 1}} =
               complete_turn(turn_ref, final)

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at

      assert %OutboxEntry{} =
               Repo.get_by!(OutboxEntry,
                 agent_uid: agent.uid,
                 binding_name: "mock",
                 outbound_key: "ai-reply:#{final.id}"
               )

      Repo.delete!(final)

      assert {:ok, %{status: :already_completed}} = complete_turn(turn_ref, final)

      assert Repo.aggregate(
               from(entry in OutboxEntry,
                 where: entry.source_actor_event_id == ^event.id
               ),
               :count
             ) == 1
    end

    test "accepts an older main delivery when an accepted steer advances the completion revision" do
      %{agent: agent, event: event, turn_ref: initial_turn_ref} = start_accepted_turn("steer")

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "mock",
                 group_entry(%{text: "/steer include the latest fact", explicit: true}),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert steer_event.type == "command.steer"
      assert is_nil(steer_event.completed_at)

      activation =
        Repo.get_by!(ActorSessionActivation,
          activation_uid: initial_turn_ref["activation_uid"]
        )

      activation =
        activation
        |> ActorSessionActivation.changeset(%{revision: initial_turn_ref["revision"] + 1})
        |> Repo.update!()

      main_delivery = Repo.get_by!(ActorEventDelivery, actor_event_id: event.id)

      %ActorEventDelivery{}
      |> ActorEventDelivery.changeset(%{
        actor_event_id: steer_event.id,
        agent_uid: agent.uid,
        session_id: event.session_id,
        queue_sequence: steer_event.queue_sequence,
        attempt_no: 1,
        actor_lane_message_id: "steer-delivery-#{Ecto.UUID.generate()}",
        correlation_id: "steer-delivery",
        activation_uid: activation.activation_uid,
        actor_epoch: activation.actor_epoch,
        actor_event_id_fence: event.id,
        revision: activation.revision,
        worker_id: main_delivery.worker_id,
        transport_route: main_delivery.transport_route,
        state: "accepted",
        send_outcome: "sent_or_queued",
        sent_at: DateTime.utc_now(:microsecond),
        accepted_at: DateTime.utc_now(:microsecond),
        error: %{}
      })
      |> Repo.insert!()

      completion_turn_ref = Map.put(initial_turn_ref, "revision", activation.revision)

      final = complete_response(agent.uid, event, "steered done")

      assert {:ok, %{status: :turn_completed, deleted_deliveries: 2}} =
               complete_turn(completion_turn_ref, final)

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at
    end

    test "tombstoned source becomes terminal without provider outbox or redelivery" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("tombstone")
      final = complete_response(agent.uid, event, "must not be sent")

      %InputTombstone{}
      |> InputTombstone.changeset(%{
        agent_uid: agent.uid,
        binding_name: event.binding_name,
        signal_channel_id: event.signal_channel_id,
        source_entry_id: event.source_entry_id,
        tombstoned_until: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
      })
      |> Repo.insert!()

      assert {:ok, %{status: :turn_canceled, reason: :actor_event_canceled}} =
               complete_turn(turn_ref, final)

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
      refute Repo.get_by(OutboxEntry, source_actor_event_id: event.id)

      live_states = ActorEventDelivery.live_states()

      refute Repo.exists?(
               from(delivery in ActorEventDelivery,
                 where: delivery.actor_event_id_fence == ^event.id,
                 where: delivery.state in ^live_states
               )
             )
    end

    test "commits a clarify-only projection without inventing final text" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("clarify-only")

      final =
        complete_response_items(agent.uid, event, [
          %{
            "type" => "function_call",
            "call_id" => "call-clarify-only",
            "name" => "clarify",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call-clarify-only",
            "output" => %{
              "tool" => "clarify",
              "ok" => true,
              "question" => "Who should receive the report?",
              "choices" => [%{"label" => "Operators"}, %{"label" => "Executives"}]
            }
          }
        ])

      assert {:ok,
              %{
                status: :turn_completed,
                outboxes: %{clarify: %OutboxEntry{} = outbox, final: nil, attachments: []}
              }} = complete_turn(turn_ref, final)

      assert outbox.payload["metadata"]["source"] == "ai_gateway_clarify"
      assert outbox.payload["text"] =~ "Who should receive the report?"

      assert Enum.map(outbox.payload["interactive_output"]["choices"], & &1["label"]) ==
               ["Operators", "Executives", "Other / free input"]

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end

    test "commits an attachment-only projection" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("attachment-only")

      attachment = %{
        "agent_computer_path" => "/workspace/user-files/reports/result.txt",
        "user_files_relative_path" => "reports/result.txt",
        "name" => "result.txt",
        "mime_type" => "text/plain",
        "size" => 42
      }

      final =
        complete_response_items(agent.uid, event, [
          %{
            "type" => "function_call",
            "call_id" => "call-attachment-only",
            "name" => "reply_attachment",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call-attachment-only",
            "output" => %{
              "tool" => "reply_attachment",
              "ok" => true,
              "attachments" => [attachment]
            }
          }
        ])

      assert {:ok,
              %{
                status: :turn_completed,
                outboxes: %{attachments: [%OutboxEntry{} = outbox], clarify: nil, final: nil}
              }} = complete_turn(turn_ref, final)

      assert outbox.outbound_key == "ai-reply-attachment:#{final.id}:0"
      assert outbox.payload["attachments"] == [attachment]
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end

    test "edits the first preview entry when committing final text" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("preview-edit")
      preview_source_entry_id = "preview-#{Ecto.UUID.generate()}"

      event
      |> ActorEvent.changeset(%{reply_preview_source_entry_id: preview_source_entry_id})
      |> Repo.update!()

      final = complete_response(agent.uid, event, "replace the preview")

      assert {:ok, %{status: :turn_completed}} = complete_turn(turn_ref, final)

      outbox =
        Repo.get_by!(OutboxEntry,
          agent_uid: agent.uid,
          binding_name: "mock",
          outbound_key: "ai-reply:#{final.id}"
        )

      assert outbox.operation == :edit
      assert outbox.target_source_entry_id == preview_source_entry_id
      assert is_nil(outbox.reply_to_source_entry_id)
    end

    test "rejects an ordinary turn with no user-visible projection" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("empty")
      final = complete_response_items(agent.uid, event, [])

      assert {:error, :turn_completion_has_no_user_visible_projection} =
               complete_turn(turn_ref, final)

      assert_turn_remains_open(event)
    end

    test "rejects a stale actor epoch without modifying Actor state" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("stale-fence")
      final = complete_response(agent.uid, event, "must not commit")
      stale_turn_ref = Map.update!(turn_ref, "actor_epoch", &(&1 + 1))

      assert {:error, :stale_actor_epoch} = complete_turn(stale_turn_ref, final)
      assert_turn_remains_open(event)
    end

    test "rejects a Response owned by another subject without modifying Actor state" do
      %{event: event, turn_ref: turn_ref} = start_accepted_turn("wrong-subject")
      %{principal: other_subject} = Ankole.PrincipalsFixtures.agent_fixture()

      final = complete_response(other_subject.uid, event, "not this subject")

      assert {:error, :not_found} = complete_turn(turn_ref, final)
      assert_turn_remains_open(event)
    end

    test "rejects a Response from another conversation without modifying Actor state" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("wrong-conversation")

      final =
        complete_response(agent.uid, event, "not this conversation",
          conversation_key: "another-session-#{Ecto.UUID.generate()}"
        )

      assert {:error, :response_conversation_mismatch} = complete_turn(turn_ref, final)
      assert_turn_remains_open(event)
    end

    test "rejects opaque metadata for another ActorEvent without modifying Actor state" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("wrong-metadata")

      final =
        complete_response(agent.uid, event, "not this event",
          actor_event_id: Ecto.UUID.generate()
        )

      assert {:error, :response_actor_event_mismatch} = complete_turn(turn_ref, final)
      assert_turn_remains_open(event)
    end

    test "rejects a failed Response without modifying Actor state" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("failed-response")
      run = start_response(agent.uid, event)

      assert {:ok, failed} =
               StatefulResponses.commit_error(
                 run,
                 [],
                 %{"code" => "provider_failed", "message" => "provider failed"}
               )

      assert {:error, :final_response_not_terminal_success} = complete_turn(turn_ref, failed)
      assert_turn_remains_open(event)
    end

    test "rejects a generating Response without modifying Actor state" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("generating-response")

      generating = start_response(agent.uid, event)

      assert {:error, :final_response_not_terminal_success} =
               complete_turn(turn_ref, generating)

      assert_turn_remains_open(event)
    end

    test "accepts an incomplete Response as a terminal user-visible projection" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("incomplete-response")

      final =
        complete_response(agent.uid, event, "partial but user-visible",
          terminal_metadata: %{
            "response" => %{"status" => "incomplete"},
            "incomplete_details" => %{"reason" => "max_output_tokens"}
          }
        )

      assert {:ok, %{status: :turn_completed}} = complete_turn(turn_ref, final)
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end

    test "iteration exhaustion is terminal and recorded in outbox metadata" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("iteration-exhausted")

      final = complete_response(agent.uid, event, "budget summary")

      assert {:ok,
              %{
                status: :turn_completed,
                outcome: "iteration_exhausted",
                outboxes: %{final: %OutboxEntry{} = outbox}
              }} = complete_turn(turn_ref, final, "iteration_exhausted")

      assert outbox.payload["metadata"]["turn_completion_outcome"] ==
               "iteration_exhausted"

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at

      refute Repo.exists?(
               from(delivery in ActorEventDelivery,
                 where: delivery.actor_event_id_fence == ^event.id,
                 where: delivery.state in ^ActorEventDelivery.live_states()
               )
             )
    end
  end

  defp start_accepted_turn(suffix) do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{actor_event: event}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 source_event_id: "turn-completion-#{suffix}",
                 signal_channel_id: "mock:chat:turn-completion-#{suffix}",
                 source_entry_id: "human-turn-completion-#{suffix}",
                 provider_thread_id: "mock-thread-turn-completion-#{suffix}",
                 text: "finish this",
                 explicit: true
               }),
               now: @base_time
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

    %{agent: agent, event: event, turn_ref: turn_ref}
  end

  defp complete_response(subject_uid, event, text, opts \\ []) do
    complete_response_items(
      subject_uid,
      event,
      [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ],
      opts
    )
  end

  defp complete_response_items(subject_uid, event, response_items, opts \\ []) do
    run = start_response(subject_uid, event, opts)

    assert {:ok, final} =
             StatefulResponses.commit_complete(
               run,
               response_items,
               Keyword.get(opts, :terminal_metadata, %{})
             )

    final
  end

  defp start_response(subject_uid, event, opts \\ []) do
    conversation_key = Keyword.get(opts, :conversation_key, event.session_id)
    actor_event_id = Keyword.get(opts, :actor_event_id, event.id)
    {:ok, conversation} = StatefulResponses.ensure_conversation(subject_uid, conversation_key)

    {:ok, run} =
      StatefulResponses.start_response_run(%{
        subject_uid: subject_uid,
        conversation_id: conversation.id,
        request_items: [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "finish this"}]
          }
        ],
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}}
      })

    run
  end

  defp complete_turn(turn_ref, final, outcome \\ "loop_finished") do
    ActorRuntime.handle_turn_completed(%{
      "turn_completed" => %{
        "turn" => turn_ref,
        "final_response_id" => "resp_#{final.id}",
        "outcome" => outcome
      }
    })
  end

  defp assert_turn_remains_open(event) do
    assert is_nil(Repo.get!(ActorEvent, event.id).completed_at)

    refute Repo.exists?(
             from(entry in OutboxEntry, where: entry.source_actor_event_id == ^event.id)
           )

    assert Repo.exists?(
             from(delivery in ActorEventDelivery,
               where: delivery.actor_event_id_fence == ^event.id,
               where: delivery.state == "accepted"
             )
           )
  end
end
