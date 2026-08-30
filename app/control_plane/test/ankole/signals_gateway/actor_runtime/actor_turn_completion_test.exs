defmodule Ankole.SignalsGateway.ActorRuntime.ActorTurnCompletionTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.Conversations

  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.Schedule.Delivery

  setup context do
    Ankole.SignalsGateway.ActorRuntimeCase.use_mock_signal_provider_plugin(context)
  end

  describe "turn_completed" do
    test "completion RPC commits once and acknowledges a retry after live fences are cleared" do
      %{agent: agent, event: event, turn_ref: turn_ref, route: route} =
        start_accepted_turn("completion-rpc")

      final = complete_response(agent.uid, event, "done")

      payload = %FabricProto.ActorTurnCompleteRequest{
        final_response_id: "resp_#{final.id}",
        outcome: "loop_finished"
      }

      assert {:ok, first_envelope} =
               RPCLane.handle_request(
                 rpc_request("complete-rpc-1", "actor_turn.complete", payload, turn: turn_ref),
                 route
               )

      first =
        rpc_response_payload!(first_envelope, FabricProto.ActorTurnCompleteResponse)

      assert first.status == "turn_completed"
      assert first.final_response_id == "resp_#{final.id}"
      assert first.outcome == "loop_finished"

      assert {:ok, retry_envelope} =
               RPCLane.handle_request(
                 rpc_request("complete-rpc-2", "actor_turn.complete", payload, turn: turn_ref),
                 route
               )

      retry =
        rpc_response_payload!(retry_envelope, FabricProto.ActorTurnCompleteResponse)

      assert retry.status == "already_completed"
      assert retry.final_response_id == first.final_response_id
      assert retry.outcome == first.outcome

      assert Repo.aggregate(
               from(entry in OutboxEntry,
                 where: entry.source_actor_event_id == ^event.id
               ),
               :count
             ) == 1
    end

    test "one cron completion creates independently retryable outboxes for every target" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("cron-delivery-fanout")

      secondary_channel_id = "mock:chat:cron-delivery-secondary"

      %Channel{}
      |> Channel.changeset(%{
        id: secondary_channel_id,
        kind: :im_group,
        reply_mode: :channel,
        name: "Secondary schedule delivery",
        metadata: %{},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })
      |> Repo.insert!()

      targets = [
        %{
          "binding_name" => event.binding_name,
          "signal_channel_id" => event.signal_channel_id,
          "provider_thread_id" => event.provider_thread_id
        },
        %{
          "binding_name" => event.binding_name,
          "signal_channel_id" => secondary_channel_id,
          "provider_thread_id" => "secondary-thread"
        }
      ]

      event =
        event
        |> ActorEvent.changeset(%{
          type: "cron.fire",
          source_entry_id: nil,
          payload: %{
            "data" => %{
              "wake_payload" => %{
                "delivery" => %{"targets" => targets},
                "payload" => %{"task" => "prepare one report"}
              }
            }
          }
        })
        |> Repo.update!()

      final = complete_response(agent.uid, event, "one report for both targets")

      assert {:ok,
              %{
                status: :turn_completed,
                outboxes: %{finals: [%OutboxEntry{} = primary, %OutboxEntry{} = secondary]}
              }} = complete_turn(turn_ref, final)

      assert primary.outbound_key == "ai-reply:#{final.id}:#{Delivery.target_key(hd(targets))}"
      assert primary.signal_channel_id == event.signal_channel_id
      assert primary.operation == :post
      assert get_in(primary.payload, ["metadata", "delivery_target", "primary"]) == true
      assert is_map(primary.payload["reply_presentation"])

      assert secondary.outbound_key ==
               "ai-reply:#{final.id}:#{Delivery.target_key(List.last(targets))}"

      assert secondary.signal_channel_id == secondary_channel_id
      assert secondary.operation == :post
      assert get_in(secondary.payload, ["metadata", "delivery_target", "primary"]) == false
      refute Map.has_key?(secondary.payload, "reply_presentation")
      assert secondary.ai_message_id == primary.ai_message_id
      assert secondary.payload["text"] == primary.payload["text"]

      success_adapter =
        outbox_adapter([:post_entry], fn _outbox ->
          {:ok, %{created_source_entry_id: "provider-primary", raw_payload: %{}}}
        end)

      assert {:ok, %OutboxEntry{status: :succeeded, attempt_count: 1}} =
               SignalsGateway.dispatch_outbox(
                 primary.agent_uid,
                 primary.binding_name,
                 primary.outbound_key,
                 success_adapter
               )

      failing_adapter =
        outbox_adapter([:post_entry], fn _outbox ->
          {:error, {:reply_delivery, :retryable, %{"code" => "provider_unavailable"}}}
        end)

      assert {:ok, %OutboxEntry{status: :failed, attempt_count: 1} = failed} =
               SignalsGateway.dispatch_outbox(
                 secondary.agent_uid,
                 secondary.binding_name,
                 secondary.outbound_key,
                 failing_adapter
               )

      retry_adapter =
        outbox_adapter([:post_entry], fn _outbox ->
          {:ok, %{created_source_entry_id: "provider-secondary", raw_payload: %{}}}
        end)

      assert {:ok, %OutboxEntry{status: :succeeded, attempt_count: 2}} =
               SignalsGateway.dispatch_outbox(
                 secondary.agent_uid,
                 secondary.binding_name,
                 secondary.outbound_key,
                 retry_adapter,
                 now: DateTime.add(failed.next_attempt_at, 1, :second)
               )

      assert Repo.get_by!(OutboxEntry,
               agent_uid: primary.agent_uid,
               binding_name: primary.binding_name,
               outbound_key: primary.outbound_key
             ).attempt_count == 1

      assert {:ok, %{status: :already_completed}} = complete_turn(turn_ref, final)

      assert Repo.aggregate(
               from(outbox in OutboxEntry, where: outbox.source_actor_event_id == ^event.id),
               :count
             ) == 2
    end

    test "one cron completion creates a target-scoped attachment outbox for every target" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("cron-attachment-fanout")

      secondary_channel_id = "mock:chat:cron-attachment-secondary"

      %Channel{}
      |> Channel.changeset(%{
        id: secondary_channel_id,
        kind: :im_group,
        reply_mode: :channel,
        name: "Secondary schedule attachment delivery",
        metadata: %{},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })
      |> Repo.insert!()

      targets = [
        %{
          "binding_name" => event.binding_name,
          "signal_channel_id" => event.signal_channel_id,
          "provider_thread_id" => event.provider_thread_id
        },
        %{
          "binding_name" => event.binding_name,
          "signal_channel_id" => secondary_channel_id,
          "provider_thread_id" => "secondary-attachment-thread"
        }
      ]

      event =
        event
        |> ActorEvent.changeset(%{
          type: "cron.fire",
          payload: %{
            "data" => %{
              "wake_payload" => %{"delivery" => %{"targets" => targets}}
            }
          }
        })
        |> Repo.update!()

      attachment = %{
        "agent_computer_path" => "/agents/#{agent.uid}/user-files/reports/scheduled.txt",
        "user_files_relative_path" => "reports/scheduled.txt",
        "name" => "scheduled.txt",
        "mime_type" => "text/plain",
        "size" => 42
      }

      final =
        complete_response_items(agent.uid, event, [
          %{
            "type" => "function_call",
            "call_id" => "call-cron-attachment",
            "name" => "reply_attachment",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call-cron-attachment",
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
                outboxes: %{
                  attachments: [
                    %OutboxEntry{} = primary,
                    %OutboxEntry{} = secondary
                  ],
                  finals: []
                }
              }} = complete_turn(turn_ref, final)

      assert primary.outbound_key ==
               "ai-reply-attachment:#{final.id}:#{Delivery.target_key(hd(targets))}:0"

      assert primary.signal_channel_id == event.signal_channel_id
      assert get_in(primary.payload, ["metadata", "delivery_target", "primary"]) == true

      assert secondary.outbound_key ==
               "ai-reply-attachment:#{final.id}:#{Delivery.target_key(List.last(targets))}:0"

      assert secondary.signal_channel_id == secondary_channel_id
      assert secondary.provider_thread_id == "secondary-attachment-thread"
      assert secondary.operation == :post
      assert is_nil(secondary.reply_to_source_entry_id)
      assert secondary.payload["attachments"] == [attachment]
      assert get_in(secondary.payload, ["metadata", "delivery_target", "primary"]) == false
    end

    test "a BackgroundAgentJob completion preserves its originating cron targets" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("background-job-delivery-fanout")

      secondary_channel_id = "mock:chat:background-job-delivery-secondary"

      %Channel{}
      |> Channel.changeset(%{
        id: secondary_channel_id,
        kind: :im_group,
        reply_mode: :channel,
        name: "Secondary background job delivery",
        metadata: %{},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })
      |> Repo.insert!()

      targets = [
        %{
          "binding_name" => event.binding_name,
          "signal_channel_id" => event.signal_channel_id,
          "provider_thread_id" => event.provider_thread_id
        },
        %{
          "binding_name" => event.binding_name,
          "signal_channel_id" => secondary_channel_id
        }
      ]

      event =
        event
        |> ActorEvent.changeset(%{
          type: "background_agent_job.completed",
          source_entry_id: nil,
          payload: %{
            "data" => %{
              "job_id" => 1000,
              "reply_route" => %{
                "binding_name" => event.binding_name,
                "signal_channel_id" => event.signal_channel_id,
                "delivery" => %{"targets" => targets}
              }
            }
          }
        })
        |> Repo.update!()

      final = complete_response(agent.uid, event, "one completed background report")

      assert {:ok,
              %{
                status: :turn_completed,
                outboxes: %{finals: [%OutboxEntry{} = primary, %OutboxEntry{} = secondary]}
              }} = complete_turn(turn_ref, final)

      assert primary.signal_channel_id == event.signal_channel_id
      assert secondary.signal_channel_id == secondary_channel_id
      assert secondary.ai_message_id == primary.ai_message_id
      assert secondary.payload["text"] == primary.payload["text"]
      refute Map.has_key?(secondary.payload, "reply_presentation")
    end

    test "noop RPC commits once and acknowledges a retry" do
      %{event: event, turn_ref: turn_ref, route: route} = start_accepted_turn("noop-rpc")
      payload = %FabricProto.ActorTurnNoopRequest{reason: "ambient_silent"}

      assert {:ok, first_envelope} =
               RPCLane.handle_request(
                 rpc_request("noop-rpc-1", "actor_turn.noop", payload, turn: turn_ref),
                 route
               )

      first = rpc_response_payload!(first_envelope, FabricProto.ActorTurnNoopResponse)
      assert first.status == "noop_completed"
      assert first.reason == "ambient_silent"
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at

      assert {:ok, retry_envelope} =
               RPCLane.handle_request(
                 rpc_request("noop-rpc-2", "actor_turn.noop", payload, turn: turn_ref),
                 route
               )

      retry = rpc_response_payload!(retry_envelope, FabricProto.ActorTurnNoopResponse)
      assert retry.status == "already_completed"
      assert retry.reason == first.reason
    end

    test "abort RPC preserves input and acknowledges a retry" do
      %{event: event, turn_ref: turn_ref, route: route} = start_accepted_turn("abort-rpc")

      payload = %FabricProto.ActorTurnAbortRequest{
        code: "worker_loop_failed",
        message: "worker loop failed",
        details_json: Torque.encode!(%{"retryable" => true})
      }

      assert {:ok, first_envelope} =
               RPCLane.handle_request(
                 rpc_request("abort-rpc-1", "actor_turn.abort", payload, turn: turn_ref),
                 route
               )

      first = rpc_response_payload!(first_envelope, FabricProto.ActorTurnAbortResponse)
      assert first.status == "turn_failed"
      refute first.dead_lettered
      assert first.retry_available_at != ""

      stored = Repo.get!(ActorEvent, event.id)
      assert stored.input_state == "open"
      assert is_nil(stored.completed_at)

      assert {:ok, retry_envelope} =
               RPCLane.handle_request(
                 rpc_request("abort-rpc-2", "actor_turn.abort", payload, turn: turn_ref),
                 route
               )

      retry = rpc_response_payload!(retry_envelope, FabricProto.ActorTurnAbortResponse)
      assert retry.status == "already_aborted"
      refute retry.dead_lettered
    end

    test "abort RPC accepts the matching attempt after its lease expires" do
      %{event: event, turn_ref: turn_ref, route: route} =
        start_accepted_turn("abort-expired-lease")

      ActorSessionActivation
      |> Repo.get_by!(activation_uid: turn_ref.activation_uid)
      |> ActorSessionActivation.changeset(%{
        lease_expires_at: DateTime.add(DateTime.utc_now(:microsecond), -1, :second)
      })
      |> Repo.update!()

      payload = %FabricProto.ActorTurnAbortRequest{
        code: "worker_loop_failed",
        message: "worker reported the failed attempt after its lease expired",
        details_json: Torque.encode!(%{"retryable" => true})
      }

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 rpc_request("abort-expired-lease", "actor_turn.abort", payload, turn: turn_ref),
                 route
               )

      response = rpc_response_payload!(envelope, FabricProto.ActorTurnAbortResponse)
      assert response.status == "turn_failed"
      assert Repo.get!(ActorEvent, event.id).input_state == "open"
      assert is_nil(Repo.get!(ActorEvent, event.id).completed_at)
    end

    test "completion RPC subsumes turn acceptance when its task runs first" do
      %{agent: agent, event: event, turn_ref: turn_ref, route: route} =
        start_sent_turn("completion-before-acceptance")

      final = complete_response(agent.uid, event, "done")

      assert {:ok, envelope} =
               RPCLane.handle_request(
                 rpc_request(
                   "complete-before-acceptance",
                   "actor_turn.complete",
                   %FabricProto.ActorTurnCompleteRequest{
                     final_response_id: "resp_#{final.id}",
                     outcome: "loop_finished"
                   },
                   turn: turn_ref
                 ),
                 route
               )

      response =
        rpc_response_payload!(envelope, FabricProto.ActorTurnCompleteResponse)

      assert response.status == "turn_completed"
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end

    test "atomically commits a final reply and is idempotent after the Response disappears" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("completion")
      final = complete_response(agent.uid, event, "done")

      assert {:ok, %{status: :turn_completed, deleted_deliveries: 1}} =
               complete_turn(turn_ref, final)

      completed_event = Repo.get!(ActorEvent, event.id)
      assert %DateTime{} = completed_event.completed_at
      assert completed_event.final_response_id == "resp_#{final.id}"
      assert completed_event.turn_outcome == "loop_finished"

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

      assert {:error, :actor_turn_completion_conflict} =
               complete_turn(turn_ref, %{final | id: Ecto.UUID.generate()})

      assert {:error, :actor_turn_completion_conflict} =
               complete_turn(turn_ref, final, "iteration_exhausted")
    end

    test "commits a provider-visible reply for a webhook receipt" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("webhook-receipt")

      event =
        event
        |> ActorEvent.changeset(%{type: "webhook.received"})
        |> Repo.update!()

      final = complete_response(agent.uid, event, "GitHub issue state verified")

      assert {:ok,
              %{
                status: :turn_completed,
                outboxes: %{finals: [%OutboxEntry{} = outbox]}
              }} = complete_turn(turn_ref, final)

      assert outbox.binding_name == event.binding_name
      assert outbox.signal_channel_id == event.signal_channel_id
      assert outbox.payload["text"] == "GitHub issue state verified"
    end

    test "completes a turn whose channel accepts no replies instead of retrying it" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("listen-only-channel")

      Channel
      |> Repo.get!(event.signal_channel_id)
      |> Channel.changeset(%{reply_mode: :none})
      |> Repo.update!()

      final = complete_response(agent.uid, event, "work is done")

      # The work happened and the answer is in the transcript. Failing the
      # completion would retry the whole turn, and every retry costs another
      # model call while the channel stays exactly as unreachable.
      assert {:ok, %{status: :turn_completed, outboxes: %{finals: [], attachments: []}}} =
               complete_turn(turn_ref, final)

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at

      assert Repo.aggregate(
               from(entry in OutboxEntry, where: entry.source_actor_event_id == ^event.id),
               :count
             ) == 0
    end

    test "moves a successful activation to warm idle and stops it normally at idle expiry" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("activation-idle")

      final = complete_response(agent.uid, event, "done")

      assert {:ok, %{status: :turn_completed}} = complete_turn(turn_ref, final)

      activation =
        Repo.get_by!(ActorSessionActivation, activation_uid: turn_ref.activation_uid)

      assert activation.status == "active"
      assert is_nil(activation.current_actor_event_id)
      assert is_nil(activation.stopped_at)
      assert is_nil(activation.stop_reason)

      assert {:ok, %ActorSessionActivation{} = stopped} =
               ActorRuntime.fail_activation_if_expired(
                 activation.activation_uid,
                 now: DateTime.add(activation.lease_expires_at, 1, :second)
               )

      assert stopped.status == "stopped"
      assert stopped.stop_reason == ":activation_idle_timeout"
      assert is_nil(stopped.current_actor_event_id)
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
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
          activation_uid: initial_turn_ref.activation_uid
        )

      activation =
        activation
        |> ActorSessionActivation.changeset(%{revision: initial_turn_ref.revision + 1})
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

      event
      |> ActorEvent.changeset(%{reply_preview_source_entry_id: "preview-before-steer"})
      |> Repo.update!()

      steer_event =
        steer_event
        |> ActorEvent.changeset(%{reply_preview_source_entry_id: "preview-after-steer"})
        |> Repo.update!()

      completion_turn_ref = %{initial_turn_ref | revision: activation.revision}

      final = complete_response(agent.uid, event, "steered done")

      assert {:ok,
              %{
                status: :turn_completed,
                deleted_deliveries: 2,
                reply_actor_event: %ActorEvent{id: reply_actor_event_id}
              }} =
               complete_turn(completion_turn_ref, final)

      assert reply_actor_event_id == steer_event.id

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{final.id}")
      assert outbox.source_actor_event_id == steer_event.id
      assert outbox.operation == :edit
      assert outbox.target_source_entry_id == "preview-after-steer"

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
      assert %DateTime{} = Repo.get!(ActorEvent, steer_event.id).completed_at
    end

    test "completes only the applied prefix when a newer steer is still pending" do
      %{agent: agent, event: event, turn_ref: initial_turn_ref} =
        start_accepted_turn("pending-steer")

      assert {:ok, %{actor_event: steer_event}} =
               emit_entry(
                 agent.uid,
                 "mock",
                 group_entry(%{
                   source_event_id: "pending-steer-command",
                   signal_channel_id: event.signal_channel_id,
                   source_entry_id: "pending-steer-entry",
                   provider_thread_id: event.provider_thread_id,
                   text: "/steer use the new direction",
                   explicit: true
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert {:ok, %{status: :active_steer_nudged, send_outcome: "sent_or_queued"}} =
               process_ready_events_once(now: DateTime.add(@base_time, 3, :second))

      assert_receive {:actor_lane, mailbox_envelope}, 2_000
      assert envelope_body_type(mailbox_envelope) == :mailbox_updated

      final = complete_response(agent.uid, event, "done before steer application")

      assert {:ok, %{status: :turn_completed, deleted_deliveries: 1, superseded_deliveries: 1}} =
               complete_turn(initial_turn_ref, final)

      assert Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{final.id}").source_actor_event_id ==
               event.id

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
      assert is_nil(Repo.get!(ActorEvent, steer_event.id).completed_at)

      assert {:ok, %{turn_ref: next_turn_ref}} =
               process_ready_events_once(
                 now: DateTime.add(@base_time, 4, :second),
                 lease_seconds: @long_lease_seconds
               )

      assert next_turn_ref.actor_event_id == steer_event.id
      assert_receive {:actor_lane, next_envelope}, 2_000
      assert turn_start_payload!(next_envelope).turn.actor_event_id == steer_event.id
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

    test "completes a channel-less internal turn without provider outboxes" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("channel-less-internal")

      event =
        event
        |> ActorEvent.changeset(%{type: "internal.no_channel", signal_channel_id: nil})
        |> Repo.update!()

      final = complete_response(agent.uid, event, "source learning completed")

      assert {:ok,
              %{
                status: :turn_completed,
                outboxes: %{attachments: [], clarify: nil, finals: []}
              }} = complete_turn(turn_ref, final)

      completed_event = Repo.get!(ActorEvent, event.id)
      assert %DateTime{} = completed_event.completed_at
      assert completed_event.final_response_id == "resp_#{final.id}"
      refute Repo.get_by(OutboxEntry, source_actor_event_id: event.id)
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
              "choices" => [
                %{"label" => "Operators", "description" => "People running the system."},
                %{"label" => "Executives"}
              ]
            }
          }
        ])

      assert {:ok,
              %{
                status: :turn_completed,
                outboxes: %{clarify: %OutboxEntry{} = outbox, finals: [], attachments: []}
              }} = complete_turn(turn_ref, final)

      assert outbox.payload["metadata"]["source"] == "ai_gateway_clarify"
      assert outbox.payload["text"] =~ "Who should receive the report?"

      assert Enum.map(outbox.payload["interactive_output"]["choices"], & &1["label"]) ==
               ["Operators", "Executives"]

      assert outbox.payload["interactive_output"]["free_input"]

      presentation = outbox.payload["reply_presentation"]
      assert presentation["interaction_status"] == "pending"
      assert hd(presentation["actions"])["description"] == "People running the system."
      assert Enum.any?(presentation["actions"], &(&1["type"] == "form"))

      persisted = Repo.get!(ActorEvent, event.id)
      assert %DateTime{} = persisted.completed_at

      assert %{"state" => "pending"} =
               persisted.reply_preview_checkpoint["interactions"]["clarify:call-clarify-only"]
    end

    test "a clarification starts superseded when a newer turn is already queued" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("clarify-with-newer-turn")

      assert {:ok, newer_event} =
               Repo.transact(fn repo ->
                 SignalsGateway.append_actor_event_in_tx(repo, %{
                   agent_uid: event.agent_uid,
                   binding_name: event.binding_name,
                   session_id: event.session_id,
                   source_event_id: "newer-than-clarify-#{event.id}",
                   signal_channel_id: event.signal_channel_id,
                   source_entry_id: "newer-entry-#{event.id}",
                   type: "im.message.addressed",
                   available_at: @base_time,
                   payload: %{"type" => "im.message.addressed", "data" => %{"entry" => %{}}}
                 })
               end)

      assert newer_event.queue_sequence > event.queue_sequence

      final =
        complete_response_items(agent.uid, event, [
          %{
            "type" => "function_call",
            "call_id" => "call-already-superseded",
            "name" => "clarify",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call-already-superseded",
            "output" => %{
              "tool" => "clarify",
              "ok" => true,
              "question" => "Which scope?",
              "choices" => [%{"label" => "All"}]
            }
          }
        ])

      assert {:ok, %{outboxes: %{clarify: %OutboxEntry{} = outbox}}} =
               complete_turn(turn_ref, final)

      checkpoint = Repo.get!(ActorEvent, event.id).reply_preview_checkpoint

      assert checkpoint["interactions"]["clarify:call-already-superseded"]["state"] ==
               "superseded"

      projected =
        ReplyInteractionState.project(outbox.payload["reply_presentation"], checkpoint)

      assert projected["interaction_status"] == "superseded"
      assert Enum.all?(projected["actions"], & &1["disabled"])
    end

    test "commits an attachment-only projection" do
      %{agent: agent, event: event, turn_ref: turn_ref} =
        start_accepted_turn("attachment-only")

      attachment = %{
        "agent_computer_path" => "/agents/#{agent.uid}/user-files/reports/result.txt",
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
                outboxes: %{attachments: [%OutboxEntry{} = outbox], clarify: nil, finals: []}
              }} = complete_turn(turn_ref, final)

      assert outbox.outbound_key == "ai-reply-attachment:#{final.id}:0"
      assert outbox.payload["attachments"] == [attachment]
      assert is_nil(outbox.fallback_visible_text)
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end

    test "keeps the final answer text out of the attachment projection" do
      %{agent: agent, event: event, turn_ref: turn_ref} = start_accepted_turn("attachment-text")

      attachment = %{
        "agent_computer_path" => "/agents/#{agent.uid}/user-files/reports/summary.docx",
        "user_files_relative_path" => "reports/summary.docx",
        "name" => "summary.docx",
        "mime_type" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "size" => 15_341
      }

      final =
        complete_response_items(agent.uid, event, [
          %{
            "type" => "function_call",
            "call_id" => "call-attachment-text",
            "name" => "reply_attachment",
            "arguments" => "{}"
          },
          %{
            "type" => "function_call_output",
            "call_id" => "call-attachment-text",
            "output" => %{
              "tool" => "reply_attachment",
              "ok" => true,
              "attachments" => [attachment]
            }
          },
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "the file is prepared"}]
          }
        ])

      assert {:ok,
              %{
                outboxes: %{
                  attachments: [%OutboxEntry{} = attachment_outbox],
                  finals: [%OutboxEntry{} = final_outbox]
                }
              }} = complete_turn(turn_ref, final)

      assert is_nil(attachment_outbox.fallback_visible_text)
      refute Map.has_key?(attachment_outbox.payload, "text")
      assert final_outbox.fallback_visible_text == "the file is prepared"
      assert final_outbox.payload["text"] == "the file is prepared"
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
      stale_turn_ref = %{turn_ref | actor_epoch: turn_ref.actor_epoch + 1}

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
                outboxes: %{finals: [%OutboxEntry{} = outbox]}
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
    result = start_sent_turn(suffix)

    assert {:ok, [%ActorEventDelivery{state: "accepted"}]} =
             ActorRuntime.handle_turn_accepted(turn_accepted_payload(result.turn_ref))

    result
  end

  defp start_sent_turn(suffix) do
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
    turn_ref = turn_start_payload!(envelope).turn

    %{agent: agent, event: event, turn_ref: turn_ref, route: route}
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
    {:ok, conversation} = Conversations.ensure_conversation(subject_uid, conversation_key)

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
    commit_turn_completion(turn_ref, "resp_#{final.id}", outcome)
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
