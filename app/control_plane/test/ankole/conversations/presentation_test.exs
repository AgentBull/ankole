defmodule Ankole.Conversations.PresentationTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  import Ankole.FilesFixtures, only: [sent_attachment_fixture: 4]

  alias Ankole.AIGateway.Conversations

  alias Ankole.SignalsGateway.Channel
  alias Ankole.Conversations.{Admission, Run, Revisions, Presentation}
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.ReplyInteractionState
  alias Ankole.Schedule.Delivery

  setup context do
    Ankole.SignalsGateway.ActorRuntimeCase.use_mock_signal_provider_plugin(context)
  end

  describe "durable terminal projection" do
    test "one cron completion creates independently retryable outboxes for every target" do
      %{agent: agent, event: event, run: run} =
        admit_event("cron-delivery-fanout")

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

      final =
        complete_response(
          agent.uid,
          event,
          Ankole.JSON.encode!(%{outcome: "reply", reply: "one report for both targets"})
        )

      assert {:ok,
              %{
                status: :completed,
                outboxes: %{finals: [%OutboxEntry{} = primary, %OutboxEntry{} = secondary]}
              }} = finalize_run(run, final)

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

      assert {:error, :run_closed} = finalize_run(run, final)

      assert Repo.aggregate(
               from(outbox in OutboxEntry, where: outbox.source_actor_event_id == ^event.id),
               :count
             ) == 2
    end

    test "one cron completion creates a target-scoped attachment outbox for every target" do
      %{agent: agent, event: event, run: run} =
        admit_event("cron-attachment-fanout")

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

      attachment =
        sent_attachment_fixture(agent.uid, "scheduled.txt", "scheduled report", "text/plain")

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
                status: :completed,
                outboxes: %{
                  attachments: [
                    %OutboxEntry{} = primary,
                    %OutboxEntry{} = secondary
                  ],
                  finals: []
                }
              }} = finalize_run(run, final)

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
      %{agent: agent, event: event, run: run} =
        admit_event("background-job-delivery-fanout")

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
                status: :completed,
                outboxes: %{finals: [%OutboxEntry{} = primary, %OutboxEntry{} = secondary]}
              }} = finalize_run(run, final)

      assert primary.signal_channel_id == event.signal_channel_id
      assert secondary.signal_channel_id == secondary_channel_id
      assert secondary.ai_message_id == primary.ai_message_id
      assert secondary.payload["text"] == primary.payload["text"]
      refute Map.has_key?(secondary.payload, "reply_presentation")
    end

    test "atomically commits a final reply and is idempotent after the Response disappears" do
      %{agent: agent, event: event, run: run} = admit_event("completion")
      final = complete_response(agent.uid, event, "done")

      assert {:ok, %{status: :completed}} =
               finalize_run(run, final)

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

      assert {:error, :run_closed} = finalize_run(run, final)

      assert Repo.aggregate(
               from(entry in OutboxEntry,
                 where: entry.source_actor_event_id == ^event.id
               ),
               :count
             ) == 1

      assert {:error, :run_closed} =
               finalize_run(run, %{final | id: Ecto.UUID.generate()})

      assert {:error, :run_closed} =
               finalize_run(run, final, "iteration_exhausted")
    end

    test "commits a provider-visible reply for a webhook receipt" do
      %{agent: agent, event: event, run: run} =
        admit_event("webhook-receipt")

      event =
        event
        |> ActorEvent.changeset(%{type: "webhook.received"})
        |> Repo.update!()

      final = complete_response(agent.uid, event, "GitHub issue state verified")

      assert {:ok,
              %{
                status: :completed,
                outboxes: %{finals: [%OutboxEntry{} = outbox]}
              }} = finalize_run(run, final)

      assert outbox.binding_name == event.binding_name
      assert outbox.signal_channel_id == event.signal_channel_id
      assert outbox.payload["text"] == "GitHub issue state verified"
    end

    test "completes a turn whose channel accepts no replies instead of retrying it" do
      %{agent: agent, event: event, run: run} =
        admit_event("listen-only-channel")

      Channel
      |> Repo.get_by!(id: event.signal_channel_id)
      |> Channel.changeset(%{reply_mode: :none})
      |> Repo.update!()

      final = complete_response(agent.uid, event, "work is done")

      # The work happened and the answer is in the transcript. Failing the
      # completion would retry the whole turn, and every retry costs another
      # model call while the channel stays exactly as unreachable.
      assert {:ok, %{status: :completed, outboxes: %{finals: [], attachments: []}}} =
               finalize_run(run, final)

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at

      assert Repo.aggregate(
               from(entry in OutboxEntry, where: entry.source_actor_event_id == ^event.id),
               :count
             ) == 0
    end

    test "completes a channel-less internal turn without provider outboxes" do
      %{agent: agent, event: event, run: run} =
        admit_event("channel-less-internal")

      event =
        event
        |> ActorEvent.changeset(%{type: "internal.no_channel", signal_channel_id: nil})
        |> Repo.update!()

      final = complete_response(agent.uid, event, "source learning completed")

      assert {:ok,
              %{
                status: :completed,
                outboxes: %{attachments: [], clarify: nil, finals: []}
              }} = finalize_run(run, final)

      completed_event = Repo.get!(ActorEvent, event.id)
      assert %DateTime{} = completed_event.completed_at
      assert completed_event.final_response_id == "resp_#{final.id}"
      refute Repo.get_by(OutboxEntry, source_actor_event_id: event.id)
    end

    test "commits a clarify-only projection without inventing final text" do
      %{agent: agent, event: event, run: run} = admit_event("clarify-only")

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
                status: :completed,
                outboxes: %{clarify: %OutboxEntry{} = outbox, finals: [], attachments: []}
              }} = finalize_run(run, final)

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
      %{agent: agent, event: event, run: run} =
        admit_event("clarify-with-newer-turn")

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
               finalize_run(run, final)

      checkpoint = Repo.get!(ActorEvent, event.id).reply_preview_checkpoint

      assert checkpoint["interactions"]["clarify:call-already-superseded"]["state"] ==
               "superseded"

      projected =
        ReplyInteractionState.project(outbox.payload["reply_presentation"], checkpoint)

      assert projected["interaction_status"] == "superseded"
      assert Enum.all?(projected["actions"], & &1["disabled"])
    end

    test "commits an attachment-only projection" do
      %{agent: agent, event: event, run: run} =
        admit_event("attachment-only")

      attachment = sent_attachment_fixture(agent.uid, "result.txt", "result", "text/plain")

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
                status: :completed,
                outboxes: %{attachments: [%OutboxEntry{} = outbox], clarify: nil, finals: []}
              }} = finalize_run(run, final)

      assert outbox.outbound_key == "ai-reply-attachment:#{final.id}:0"
      assert outbox.payload["attachments"] == [attachment]
      assert is_nil(outbox.fallback_visible_text)
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end

    test "keeps the final answer text out of the attachment projection" do
      %{agent: agent, event: event, run: run} = admit_event("attachment-text")

      attachment =
        sent_attachment_fixture(
          agent.uid,
          "summary.docx",
          "summary",
          "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )

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
              }} = finalize_run(run, final)

      assert is_nil(attachment_outbox.fallback_visible_text)
      refute Map.has_key?(attachment_outbox.payload, "text")
      assert final_outbox.fallback_visible_text == "the file is prepared"
      assert final_outbox.payload["text"] == "the file is prepared"
    end

    test "edits the first preview entry when committing final text" do
      %{agent: agent, event: event, run: run} = admit_event("preview-edit")
      preview_source_entry_id = "preview-#{Ecto.UUID.generate()}"

      event
      |> ActorEvent.changeset(%{reply_preview_source_entry_id: preview_source_entry_id})
      |> Repo.update!()

      final = complete_response(agent.uid, event, "replace the preview")

      assert {:ok, %{status: :completed}} = finalize_run(run, final)

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
      %{agent: agent, event: event, run: run} = admit_event("empty")
      final = complete_response_items(agent.uid, event, [])

      assert {:error, :turn_completion_has_no_user_visible_projection} =
               finalize_run(run, final)

      assert_turn_remains_open(event)
    end

    test "rejects a stale actor epoch without modifying Actor state" do
      %{agent: agent, event: event, run: run} = admit_event("stale-fence")
      final = complete_response(agent.uid, event, "must not commit")
      stale_run = %{run | epoch: run.epoch + 1}

      assert {:error, :stale_driver} = finalize_run(stale_run, final)
      assert_turn_remains_open(event)
    end

    test "rejects a Response owned by another subject without modifying Actor state" do
      %{event: event, run: run} = admit_event("wrong-subject")
      %{principal: other_subject} = Ankole.PrincipalsFixtures.agent_fixture()

      final = complete_response(other_subject.uid, event, "not this subject")

      assert {:error, :not_found} = finalize_run(run, final)
      assert_turn_remains_open(event)
    end

    test "rejects a Response from another conversation without modifying Actor state" do
      %{agent: agent, event: event, run: run} =
        admit_event("wrong-conversation")

      final =
        complete_response(agent.uid, event, "not this conversation",
          conversation_key: "another-session-#{Ecto.UUID.generate()}"
        )

      assert {:error, :response_conversation_mismatch} = finalize_run(run, final)
      assert_turn_remains_open(event)
    end

    test "rejects opaque metadata for another ActorEvent without modifying Actor state" do
      %{agent: agent, event: event, run: run} = admit_event("wrong-metadata")

      final =
        complete_response(agent.uid, event, "not this event",
          actor_event_id: Ecto.UUID.generate()
        )

      assert {:error, :response_actor_event_mismatch} = finalize_run(run, final)
      assert_turn_remains_open(event)
    end

    test "rejects a failed Response without modifying Actor state" do
      %{agent: agent, event: event, run: run} = admit_event("failed-response")
      model_run = start_response(agent.uid, event)

      assert {:ok, failed} =
               StatefulResponses.commit_error(
                 model_run,
                 [],
                 %{"code" => "provider_failed", "message" => "provider failed"}
               )

      assert {:error, :final_response_not_terminal_success} = finalize_run(run, failed)
      assert_turn_remains_open(event)
    end

    test "rejects a generating Response without modifying Actor state" do
      %{agent: agent, event: event, run: run} =
        admit_event("generating-response")

      generating = start_response(agent.uid, event)

      assert {:error, :final_response_not_terminal_success} =
               finalize_run(run, generating)

      assert_turn_remains_open(event)
    end

    test "accepts an incomplete Response as a terminal user-visible projection" do
      %{agent: agent, event: event, run: run} =
        admit_event("incomplete-response")

      final =
        complete_response(agent.uid, event, "partial but user-visible",
          terminal_metadata: %{
            "response" => %{"status" => "incomplete"},
            "incomplete_details" => %{"reason" => "max_output_tokens"}
          }
        )

      assert {:ok, %{status: :completed}} = finalize_run(run, final)
      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end

    test "iteration exhaustion is terminal and recorded in outbox metadata" do
      %{agent: agent, event: event, run: run} =
        admit_event("iteration-exhausted")

      final = complete_response(agent.uid, event, "budget summary")

      assert {:ok,
              %{
                status: :completed,
                outcome: "iteration_exhausted",
                outboxes: %{finals: [%OutboxEntry{} = outbox]}
              }} = finalize_run(run, final, "iteration_exhausted")

      assert outbox.payload["metadata"]["turn_completion_outcome"] ==
               "iteration_exhausted"

      assert %DateTime{} = Repo.get!(ActorEvent, event.id).completed_at
    end
  end

  test "ordinary appended input owns the preview and final reply after recovery" do
    %{agent: agent, event: event, run: run} = admit_event("appended-owner")
    assert :ok = Presentation.start(run, self())

    appended =
      for index <- 1..3 do
        {:ok, %{actor_event: next}} =
          emit_entry(
            agent.uid,
            event.binding_name,
            group_entry(%{
              source_event_id: "appended-#{index}",
              source_entry_id: "appended-#{index}",
              signal_channel_id: event.signal_channel_id,
              provider_thread_id: event.provider_thread_id,
              explicit: true,
              text: "Additional requirement #{index}"
            }),
            now: DateTime.add(@base_time, index, :second)
          )

        assert {:ok, [next]} = Run.inject(run, [next])
        assert :ok = Presentation.continue(run, [next])
        next
      end

    last = List.last(appended)
    generation = Repo.reload!(last).reply_preview_checkpoint["owner_generation"]
    assert [{pid, _}] = AIReplyPreview.lookup(event.id)
    assert :sys.get_state(pid).actor_event.id == last.id
    monitor = Process.monitor(pid)
    assert :ok = Presentation.stop(run)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    run = %{run | steer_event_ids: Enum.map(appended, & &1.id)}

    {:ok, model} =
      start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        metadata: %{"request_metadata" => Run.metadata(run)}
      })

    {:ok, final} =
      StatefulResponses.commit_complete(model, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "All requirements are complete."}]
        }
      ])

    {:ok, replacement} = Admission.admit(run, Repo.reload!(event))
    {:ok, {:boundary, restored}} = Run.restore(replacement)
    assert :ok = Presentation.start(restored, self())
    assert [{recovered, _}] = AIReplyPreview.lookup(event.id)
    assert :sys.get_state(recovered).actor_event.id == last.id
    assert Repo.reload!(last).reply_preview_checkpoint["owner_generation"] > generation
    assert {:ok, %{outboxes: %{finals: [box]}}} = Run.finalize(%{restored | anchor: final.id})
    assert box.source_actor_event_id == last.id
    assert box.reply_to_source_entry_id == last.source_entry_id
  end

  test "withdrawal committed before finalization prevents a reply and deletes the trigger" do
    %{agent: agent, event: event, run: run} = admit_event("withdrawn")
    final = complete_response(agent.uid, event, "must not be sent")

    Repo.insert!(
      InputTombstone.changeset(%InputTombstone{}, %{
        agent_uid: agent.uid,
        binding_name: event.binding_name,
        signal_channel_id: event.signal_channel_id,
        source_entry_id: event.source_entry_id,
        tombstoned_until: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
      })
    )

    assert {:error, :actor_event_canceled} = finalize_run(run, final)
    assert_turn_remains_open(event)

    {:ok, revision} =
      Repo.transact(fn repo ->
        SignalsGateway.append_actor_event_in_tx(repo, %{
          agent_uid: agent.uid,
          binding_name: event.binding_name,
          session_id: event.session_id,
          sender_key: agent.uid,
          source_event_id: "remove-#{event.id}",
          type: "input.revised",
          payload: %{
            "data" => %{
              "revision" => %{
                "actor_event_id" => event.id,
                "kind" => "remove",
                "entry" => %{"source_entry_id" => event.source_entry_id}
              }
            }
          },
          available_at: DateTime.utc_now(:microsecond)
        })
      end)

    assert {:ok, :stopped} = Revisions.apply(run, revision)
    refute Repo.get(ActorEvent, event.id)
    assert %ActorEvent{completed_at: %DateTime{}} = Repo.get!(ActorEvent, revision.id)
    refute Repo.get_by(OutboxEntry, source_actor_event_id: event.id)
  end

  @tag :b01
  test "context withdrawal replaces the old preview and survives late checkpoint hydration" do
    %{agent: agent, event: event, run: run} = admit_event("context-withdrawn")
    event = with_withdrawn_context(event)

    data =
      Map.put(event.payload["data"], "entries", [
        %{"source_entry_id" => event.source_entry_id},
        %{"source_entry_id" => "other-batch-input"}
      ])

    event =
      event
      |> ActorEvent.changeset(%{payload: Map.put(event.payload, "data", data)})
      |> Repo.update!()

    final = complete_response(agent.uid, event, "must not be sent")

    checkpoint = %{
      "presentation" =>
        Ankole.SignalsGateway.ReplyPresentation.new(state: "working")
        |> Ankole.SignalsGateway.ReplyPresentation.replace_answer("old context answer")
        |> Map.merge(%{
          "plan" => %{
            "operation_id" => "plan",
            "revision" => 1,
            "items" => [
              %{"id" => "old", "content" => "WITHDRAWN-PLAN", "status" => "in_progress"}
            ]
          },
          "activities" => %{
            "old" => %{"revision" => 1, "phase" => "running", "label" => "WITHDRAWN-ACTIVITY"}
          },
          "results" => [
            %{
              "kind" => "table",
              "operation_id" => "table",
              "revision" => 1,
              "columns" => [%{"key" => "value", "label" => "WITHDRAWN-RESULT"}],
              "rows" => [%{"value" => "WITHDRAWN-RESULT"}]
            }
          ],
          "receipts" => [
            %{
              "kind" => "effect",
              "operation_id" => "effect",
              "revision" => 1,
              "summary" => "WITHDRAWN-RECEIPT"
            }
          ]
        })
    }

    event =
      event
      |> ActorEvent.changeset(%{
        reply_preview_checkpoint: checkpoint,
        reply_preview_source_entry_id: "existing-preview"
      })
      |> Repo.update!()

    run = %{run | event: event, anchor: final.id}

    assert {:error, :actor_event_context_canceled} = Run.finalize(run)
    assert_turn_remains_open(event)
    refute Repo.get_by(OutboxEntry, source_actor_event_id: event.id)

    %InputTombstone{}
    |> InputTombstone.changeset(%{
      agent_uid: agent.uid,
      binding_name: event.binding_name,
      signal_channel_id: event.signal_channel_id,
      source_entry_id: "other-batch-input",
      tombstoned_until: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
    })
    |> Repo.insert!()

    assert {:ok, %{outcome: "stopped", outboxes: %{finals: [notice]}}} =
             Run.finalize(run, "stopped", :actor_event_context_canceled)

    text = Ankole.I18n.t("signals_gateway.reply.context_withdrawn")
    assert notice.source_actor_event_id == event.id
    assert notice.operation == :edit
    assert notice.target_source_entry_id == "existing-preview"
    assert notice.payload["metadata"]["reason"] == "context_withdrawn"
    assert notice.payload["reply_presentation"]["state"] == "stopped"
    assert notice.payload["reply_presentation"]["answer"] == text
    refute Ankole.JSON.encode!(notice.payload) =~ "old context answer"
    refute Ankole.JSON.encode!(notice.payload) =~ "WITHDRAWN-"

    for sentinel <- [
          "WITHDRAWN-PLAN",
          "WITHDRAWN-ACTIVITY",
          "WITHDRAWN-RESULT",
          "WITHDRAWN-RECEIPT"
        ] do
      assert Ankole.JSON.encode!(
               Ankole.SignalsGateway.ReplyPresentation.normalize(checkpoint["presentation"])
             ) =~ sentinel
    end

    assert Repo.reload!(event).completed_at

    Repo.reload!(event)
    |> ActorEvent.changeset(%{
      reply_preview_checkpoint:
        put_in(checkpoint, ["presentation", "answer"], "late context answer")
    })
    |> Repo.update!()

    parent = self()

    adapter =
      outbox_adapter([:edit_entry, :reply_entry, :post_entry], fn delivered ->
        send(parent, {:context_notice_delivery, delivered})
        {:ok, %{created_source_entry_id: "existing-preview", raw_payload: %{}}}
      end)

    assert {:ok, %OutboxEntry{status: :succeeded}} =
             SignalsGateway.dispatch_outbox(
               notice.agent_uid,
               notice.binding_name,
               notice.outbound_key,
               adapter
             )

    assert_receive {:context_notice_delivery, delivered}
    assert delivered.payload["reply_presentation"]["answer"] == text
    refute Ankole.JSON.encode!(delivered.payload) =~ "late context answer"
    refute Ankole.JSON.encode!(delivered.payload) =~ "WITHDRAWN-"
    refute Ankole.JSON.encode!(delivered.payload) =~ "must not be sent"
    assert {:error, :run_closed} = Run.finalize(run, "stopped", :actor_event_context_canceled)
  end

  @tag :b01
  test "an input withdrawn before the context-stop commit receives no notice" do
    %{agent: agent, event: event, run: run} = admit_event("context-anchor-withdrawn")
    event = with_withdrawn_context(event)
    final = complete_response(agent.uid, event, "must not be sent")
    run = %{run | event: event, anchor: final.id}
    assert {:error, :actor_event_context_canceled} = Run.finalize(run)

    %InputTombstone{}
    |> InputTombstone.changeset(%{
      agent_uid: agent.uid,
      binding_name: event.binding_name,
      signal_channel_id: event.signal_channel_id,
      source_entry_id: event.source_entry_id,
      tombstoned_until: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
    })
    |> Repo.insert!()

    assert {:ok, %{outboxes: %{finals: []}}} =
             Run.finalize(run, "stopped", :actor_event_context_canceled)

    refute Repo.get_by(OutboxEntry, source_actor_event_id: event.id)
    assert Repo.reload!(event).completed_at
  end

  defp with_withdrawn_context(event) do
    data =
      Map.put(event.payload["data"], "channel_context", %{
        "messages" => [%{"source_entry_id" => "withdrawn-context"}]
      })

    event =
      event
      |> ActorEvent.changeset(%{payload: Map.put(event.payload, "data", data)})
      |> Repo.update!()

    %InputTombstone{}
    |> InputTombstone.changeset(%{
      agent_uid: event.agent_uid,
      binding_name: event.binding_name,
      signal_channel_id: event.signal_channel_id,
      source_entry_id: "withdrawn-context",
      tombstoned_until: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
    })
    |> Repo.insert!()

    event
  end

  defp admit_event(suffix) do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    assert {:ok, %{actor_event: event}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 source_event_id: "completion-#{suffix}",
                 signal_channel_id: "mock:chat:completion-#{suffix}",
                 source_entry_id: "human-completion-#{suffix}",
                 provider_thread_id: "mock-thread-#{suffix}",
                 text: "finish this",
                 explicit: true
               }),
               now: @base_time
             )

    assert {:ok, run} =
             Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event)

    %{agent: agent, event: event, run: run}
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
      start_response_run(%{
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

  defp finalize_run(run, final, outcome \\ "loop_finished") do
    Run.finalize(
      %{run | event: Repo.get!(ActorEvent, run.actor_event_id), anchor: final.id},
      outcome
    )
  end

  defp assert_turn_remains_open(event) do
    assert %ActorEvent{completed_at: nil, input_state: "open"} = Repo.get!(ActorEvent, event.id)

    refute Repo.exists?(
             from(entry in OutboxEntry, where: entry.source_actor_event_id == ^event.id)
           )
  end
end
