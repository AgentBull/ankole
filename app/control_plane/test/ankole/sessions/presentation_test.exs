defmodule Ankole.Sessions.PresentationTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.SessionsCase

  import Ankole.FilesFixtures, only: [sent_attachment_fixture: 4]

  alias Ankole.Conversations.Conversation, as: PublicConversation
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Revisions
  alias Ankole.Sessions.Presentation
  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Conversations.InputTombstone
  alias Ankole.Conversations.Delivery.InteractionState
  alias Ankole.Schedule.Delivery

  setup context do
    Ankole.SessionsCase.use_mock_signal_provider_plugin(context)
  end

  describe "durable terminal projection" do
    test "one cron completion creates independently retryable intents for every target" do
      %{agent: agent, event: event} =
        admit_event("cron-delivery-fanout")

      secondary_provider_id = "mock:chat:cron-delivery-secondary"
      secondary_channel_id = Ecto.UUID.generate()

      Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
        id: secondary_channel_id,
        provider_conversation_id: secondary_provider_id,
        last_activity_at: @base_time,
        external_kind: :im_group,
        reply_mode: :channel,
        title: "Secondary schedule delivery",
        metadata: %{},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })

      assert {:ok, _} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(Ankole.Conversations.Participant, :join, %{
                   conversation_id: secondary_channel_id,
                   principal_uid: agent.uid,
                   role: :agent
                 })
               end)

      targets = [
        %{
          "binding_name" => event.reply_binding_name,
          "conversation_id" => event.conversation_id,
          "provider_thread_id" => event.provider_thread_id
        },
        %{
          "binding_name" => event.reply_binding_name,
          "conversation_id" => secondary_channel_id,
          "provider_thread_id" => "secondary-thread"
        }
      ]

      event =
        event
        |> AshPostgres.DataLayer.to_ecto()
        |> Ecto.Changeset.change(%{
          type: "cron.fire",
          provider_message_id: nil,
          data: %{
            "wake_payload" => %{
              "delivery" => %{"targets" => targets},
              "payload" => %{"task" => "prepare one report"}
            }
          }
        })
        |> Repo.update!()

      insert_fire_proof!(event)

      assert {:ok, run} =
               Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event)

      assert {:ok, {:preparing, run}} = Ankole.Sessions.Model.prepare(run)

      call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => "finish",
        "arguments" =>
          Ankole.JSON.encode!(%{"outcome" => "reply", "reply" => "one report for both targets"})
      }

      response = complete_response_items(agent.uid, event, [call])
      run = %{run | model_response: response, calls: [call], round_calls: [call]}
      assert {:ok, tool, args} = Ankole.Sessions.Tools.prepare(run, call)
      result = Ankole.Sessions.Tools.execute(run, call, tool, args)
      refute result.is_error
      assert {:ok, journal} = Run.record_round(%{run | results: %{call["call_id"] => result}})
      assert {:ok, {_state, run}} = Run.restore(run)
      final = journal.message

      assert {:ok,
              %{
                status: :completed,
                posted: %{intents: [%Intent{} = primary, %Intent{} = secondary]}
              }} = finalize_run(run, final)

      assert primary.outbound_key == "ai-reply:#{final.id}:#{Delivery.target_key(hd(targets))}"
      assert primary.conversation_id == event.conversation_id
      assert primary.operation == :post
      assert get_in(primary.payload, ["metadata", "delivery_target", "primary"]) == true
      assert is_map(primary.payload["reply_presentation"])

      assert secondary.outbound_key ==
               "ai-reply:#{final.id}:#{Delivery.target_key(List.last(targets))}"

      assert secondary.conversation_id == secondary_channel_id
      assert secondary.operation == :post
      assert get_in(secondary.payload, ["metadata", "delivery_target", "primary"]) == false
      refute Map.has_key?(secondary.payload, "reply_presentation")
      assert secondary.ai_message_id == primary.ai_message_id
      assert secondary.payload["text"] == primary.payload["text"]

      success_adapter =
        delivery_adapter([:post_entry], fn _intent ->
          {:ok, %{created_provider_message_id: "provider-primary", raw_payload: %{}}}
        end)

      assert {:ok, %Intent{status: :sent, attempt_count: 1}} =
               Ankole.Conversations.Delivery.dispatch(
                 primary.agent_uid,
                 primary.binding_name,
                 primary.outbound_key,
                 success_adapter
               )

      failing_adapter =
        delivery_adapter([:post_entry], fn _intent ->
          {:error, {:reply_delivery, :retryable, %{"code" => "provider_unavailable"}}}
        end)

      assert {:ok, %Intent{status: :failed, attempt_count: 1} = failed} =
               Ankole.Conversations.Delivery.dispatch(
                 secondary.agent_uid,
                 secondary.binding_name,
                 secondary.outbound_key,
                 failing_adapter
               )

      retry_adapter =
        delivery_adapter([:post_entry], fn _intent ->
          {:ok, %{created_provider_message_id: "provider-secondary", raw_payload: %{}}}
        end)

      assert {:ok, %Intent{status: :sent, attempt_count: 2}} =
               Ankole.Conversations.Delivery.dispatch(
                 secondary.agent_uid,
                 secondary.binding_name,
                 secondary.outbound_key,
                 retry_adapter,
                 now: DateTime.add(failed.next_attempt_at, 1, :second)
               )

      assert Repo.get_by!(Intent,
               agent_uid: primary.agent_uid,
               binding_name: primary.binding_name,
               outbound_key: primary.outbound_key
             ).attempt_count == 1

      assert {:error, :run_closed} = finalize_run(run, final)

      assert Repo.aggregate(
               from(intent in Intent, where: intent.source_signal_id == ^event.id),
               :count
             ) == 2
    end

    test "one cron completion creates a target-scoped attachment intent for every target" do
      %{agent: agent, event: event, run: run} =
        admit_event("cron-attachment-fanout")

      secondary_provider_id = "mock:chat:cron-attachment-secondary"
      secondary_channel_id = Ecto.UUID.generate()

      Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
        id: secondary_channel_id,
        provider_conversation_id: secondary_provider_id,
        last_activity_at: @base_time,
        external_kind: :im_group,
        reply_mode: :channel,
        title: "Secondary schedule attachment delivery",
        metadata: %{},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })

      assert {:ok, _} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(Ankole.Conversations.Participant, :join, %{
                   conversation_id: secondary_channel_id,
                   principal_uid: agent.uid,
                   role: :agent
                 })
               end)

      targets = [
        %{
          "binding_name" => event.reply_binding_name,
          "conversation_id" => event.conversation_id,
          "provider_thread_id" => event.provider_thread_id
        },
        %{
          "binding_name" => event.reply_binding_name,
          "conversation_id" => secondary_channel_id,
          "provider_thread_id" => "secondary-attachment-thread"
        }
      ]

      event =
        event
        |> AshPostgres.DataLayer.to_ecto()
        |> Ecto.Changeset.change(%{
          type: "cron.fire",
          data: %{
            "wake_payload" => %{"delivery" => %{"targets" => targets}}
          }
        })
        |> Repo.update!()

      insert_fire_proof!(event)

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
                posted: %{
                  intents: [
                    %Intent{} = primary,
                    %Intent{} = secondary
                  ]
                }
              }} = finalize_run(run, final)

      assert primary.outbound_key ==
               "ai-reply-attachment:#{final.id}:#{Delivery.target_key(hd(targets))}:0"

      assert primary.conversation_id == event.conversation_id
      assert get_in(primary.payload, ["metadata", "delivery_target", "primary"]) == true

      assert secondary.outbound_key ==
               "ai-reply-attachment:#{final.id}:#{Delivery.target_key(List.last(targets))}:0"

      assert secondary.conversation_id == secondary_channel_id
      assert secondary.provider_thread_id == "secondary-attachment-thread"
      assert secondary.operation == :post
      assert is_nil(secondary.reply_to_provider_message_id)
      assert secondary.payload["attachments"] == [attachment]
      assert get_in(secondary.payload, ["metadata", "delivery_target", "primary"]) == false
    end

    test "a BackgroundAgentJob completion preserves its originating cron targets" do
      %{agent: agent, event: event, run: run} =
        admit_event("background-job-delivery-fanout")

      secondary_provider_id = "mock:chat:background-job-delivery-secondary"
      secondary_channel_id = Ecto.UUID.generate()

      Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
        id: secondary_channel_id,
        provider_conversation_id: secondary_provider_id,
        last_activity_at: @base_time,
        external_kind: :im_group,
        reply_mode: :channel,
        title: "Secondary background job delivery",
        metadata: %{},
        raw_payload: %{},
        first_seen_at: @base_time,
        last_seen_at: @base_time
      })

      assert {:ok, _} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(Ankole.Conversations.Participant, :join, %{
                   conversation_id: secondary_channel_id,
                   principal_uid: agent.uid,
                   role: :agent
                 })
               end)

      targets = [
        %{
          "binding_name" => event.reply_binding_name,
          "conversation_id" => event.conversation_id,
          "provider_thread_id" => event.provider_thread_id
        },
        %{
          "binding_name" => event.reply_binding_name,
          "conversation_id" => secondary_channel_id
        }
      ]

      event =
        event
        |> AshPostgres.DataLayer.to_ecto()
        |> Ecto.Changeset.change(%{
          type: "background_agent_job.completed",
          provider_message_id: nil,
          data: %{
            "job_id" => 1000,
            "reply_route" => %{
              "binding_name" => event.reply_binding_name,
              "conversation_id" => event.conversation_id,
              "delivery" => %{"targets" => targets}
            }
          }
        })
        |> Repo.update!()

      final = complete_response(agent.uid, event, "one completed background report")

      assert {:ok,
              %{
                status: :completed,
                posted: %{intents: [%Intent{} = primary, %Intent{} = secondary]}
              }} = finalize_run(run, final)

      assert primary.conversation_id == event.conversation_id
      assert secondary.conversation_id == secondary_channel_id
      assert secondary.ai_message_id == primary.ai_message_id
      assert secondary.payload["text"] == primary.payload["text"]
      refute Map.has_key?(secondary.payload, "reply_presentation")
    end

    test "atomically commits a final reply and is idempotent after the Response disappears" do
      %{agent: agent, event: event, run: run} = admit_event("completion")
      final = complete_response(agent.uid, event, "done")

      assert {:ok, %{status: :completed}} =
               finalize_run(run, final)

      completed_event = Repo.get!(Signal, event.id)
      assert %DateTime{} = completed_event.completed_at
      assert completed_event.final_response_id == "resp_#{final.id}"
      assert completed_event.turn_outcome == "loop_finished"

      assert %Intent{} =
               Repo.get_by!(Intent,
                 agent_uid: agent.uid,
                 binding_name: "mock",
                 outbound_key: "ai-reply:#{final.id}"
               )

      Repo.delete!(final)

      assert {:error, :run_closed} = finalize_run(run, final)

      assert Repo.aggregate(
               from(entry in Intent,
                 where: entry.source_signal_id == ^event.id
               ),
               :count
             ) == 1

      assert {:error, :run_closed} =
               finalize_run(run, %{final | id: Ecto.UUID.generate()})

      assert {:error, :run_closed} =
               finalize_run(run, final, :iteration_exhausted)
    end

    test "commits a provider-visible reply for a webhook receipt" do
      %{agent: agent, event: event, run: run} =
        admit_event("webhook-receipt")

      event =
        event
        |> AshPostgres.DataLayer.to_ecto()
        |> Ecto.Changeset.change(%{type: "webhook.received"})
        |> Repo.update!()

      final = complete_response(agent.uid, event, "GitHub issue state verified")

      assert {:ok,
              %{
                status: :completed,
                posted: %{intents: [%Intent{} = intent]}
              }} = finalize_run(run, final)

      assert intent.binding_name == event.reply_binding_name
      assert intent.conversation_id == event.conversation_id
      assert intent.payload["text"] == "GitHub issue state verified"
    end

    test "completes a turn whose channel accepts no replies instead of retrying it" do
      %{agent: agent, event: event, run: run} =
        admit_event("listen-only-channel")

      assert {:ok, _} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.update(
                   Repo.get_by!(PublicConversation, id: event.conversation_id),
                   :observe,
                   %{reply_mode: :none}
                 )
               end)

      final = complete_response(agent.uid, event, "work is done")

      # The work happened and the answer is in the transcript. Failing the
      # completion would retry the whole turn, and every retry costs another
      # model call while the channel stays exactly as unreachable.
      assert {:ok, %{status: :completed, posted: %{intents: []}}} =
               finalize_run(run, final)

      assert %DateTime{} = Repo.get!(Signal, event.id).completed_at

      assert Repo.aggregate(
               from(entry in Intent, where: entry.source_signal_id == ^event.id),
               :count
             ) == 0
    end

    test "completes a channel-less internal turn without provider intents" do
      %{agent: agent, event: event, run: run} =
        admit_event("channel-less-internal")

      event =
        event
        |> AshPostgres.DataLayer.to_ecto()
        |> Ecto.Changeset.change(%{type: "internal.no_channel", conversation_id: nil})
        |> Repo.update!()

      final = complete_response(agent.uid, event, "source learning completed")

      assert {:ok,
              %{
                status: :completed,
                posted: %{intents: []}
              }} = finalize_run(run, final)

      completed_event = Repo.get!(Signal, event.id)
      assert %DateTime{} = completed_event.completed_at
      assert completed_event.final_response_id == "resp_#{final.id}"
      refute Repo.get_by(Intent, source_signal_id: event.id)
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
                posted: %{intents: [intent]}
              }} = finalize_run(run, final)

      assert intent.payload["metadata"]["source"] == "ai_gateway_clarify"
      assert intent.payload["text"] =~ "Who should receive the report?"

      assert Enum.map(intent.payload["interactive_output"]["choices"], & &1["label"]) ==
               ["Operators", "Executives"]

      assert intent.payload["interactive_output"]["free_input"]

      presentation = intent.payload["reply_presentation"]
      assert presentation["interaction_status"] == "pending"
      assert hd(presentation["actions"])["description"] == "People running the system."
      assert Enum.any?(presentation["actions"], &(&1["type"] == "form"))

      persisted = Repo.get!(Signal, event.id)
      assert %DateTime{} = persisted.completed_at

      assert %{"state" => "pending"} =
               Ankole.Conversations.Delivery.PreviewState.get(persisted).checkpoint[
                 "interactions"
               ]["clarify:call-clarify-only"]
    end

    test "a clarification starts superseded when a newer turn is already queued" do
      %{agent: agent, event: event, run: run} =
        admit_event("clarify-with-newer-turn")

      assert {:ok, newer_event} =
               Repo.transact(fn repo ->
                 Ankole.Signals.accept_in_tx(repo, %{
                   producer: :kernel,
                   target: %{agent_uid: event.agent_uid, session_id: event.session_id},
                   source: "test:runtime",
                   reply_route: %{
                     binding_name: event.reply_binding_name,
                     conversation_id: event.conversation_id,
                     provider_message_id: "newer-entry-#{event.id}"
                   },
                   id: "newer-than-clarify-#{event.id}",
                   data: %{"entry" => %{}},
                   type: "conversation.message.addressed",
                   available_at: @base_time,
                   authorization: Ankole.Principals.WorkAccess.service()
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

      assert {:ok, %{posted: %{intents: [intent]}}} =
               finalize_run(run, final)

      checkpoint =
        Ankole.Conversations.Delivery.PreviewState.get(Repo.get!(Signal, event.id)).checkpoint

      assert checkpoint["interactions"]["clarify:call-already-superseded"]["state"] ==
               "superseded"

      projected =
        InteractionState.project(intent.payload["reply_presentation"], checkpoint)

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
                posted: %{intents: [%Intent{} = intent]}
              }} = finalize_run(run, final)

      assert intent.outbound_key == "ai-reply-attachment:#{final.id}:0"
      assert intent.payload["attachments"] == [attachment]
      assert is_nil(intent.fallback_visible_text)
      assert %DateTime{} = Repo.get!(Signal, event.id).completed_at
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
                posted: %{
                  intents: [%Intent{} = attachment_intent, %Intent{} = final_intent]
                }
              }} = finalize_run(run, final)

      assert is_nil(attachment_intent.fallback_visible_text)
      refute Map.has_key?(attachment_intent.payload, "text")
      assert final_intent.fallback_visible_text == "the file is prepared"
      assert final_intent.payload["text"] == "the file is prepared"
    end

    test "edits the first preview entry when committing final text" do
      %{agent: agent, event: event, run: run} = admit_event("preview-edit")
      preview_provider_message_id = "preview-#{Ecto.UUID.generate()}"

      event
      |> Ankole.PreviewFixtures.update!(%{provider_message_id: preview_provider_message_id})

      final = complete_response(agent.uid, event, "replace the preview")

      assert {:ok, %{status: :completed}} = finalize_run(run, final)

      intent =
        Repo.get_by!(Intent,
          agent_uid: agent.uid,
          binding_name: "mock",
          outbound_key: "ai-reply:#{final.id}"
        )

      assert intent.operation == :edit
      assert intent.target_provider_message_id == preview_provider_message_id
      assert is_nil(intent.reply_to_provider_message_id)
    end

    test "rejects an ordinary turn with no user-visible projection" do
      %{agent: agent, event: event, run: run} = admit_event("empty")
      final = complete_response_items(agent.uid, event, [])

      assert {:error, :turn_completion_has_no_user_visible_projection} =
               finalize_run(run, final)

      assert_turn_remains_running(event)
    end

    test "rejects a stale actor epoch without modifying Actor state" do
      %{agent: agent, event: event, run: run} = admit_event("stale-fence")
      final = complete_response(agent.uid, event, "must not commit")
      stale_run = %{run | epoch: run.epoch + 1}

      assert {:error, :stale_driver} = finalize_run(stale_run, final)
      assert_turn_remains_running(event)
    end

    test "rejects a Response owned by another subject without modifying Actor state" do
      %{event: event, run: run} = admit_event("wrong-subject")
      %{principal: other_subject} = Ankole.PrincipalsFixtures.agent_fixture()

      final = complete_response(other_subject.uid, event, "not this subject")

      assert {:error, :not_found} = finalize_run(run, final)
      assert_turn_remains_running(event)
    end

    test "rejects a Response from another conversation without modifying Actor state" do
      %{agent: agent, event: event, run: run} =
        admit_event("wrong-conversation")

      final =
        complete_response(agent.uid, event, "not this conversation",
          conversation_key: "another-session-#{Ecto.UUID.generate()}"
        )

      assert {:error, :response_conversation_mismatch} = finalize_run(run, final)
      assert_turn_remains_running(event)
    end

    test "rejects opaque metadata for another Signal without modifying Actor state" do
      %{agent: agent, event: event, run: run} = admit_event("wrong-metadata")

      final =
        complete_response(agent.uid, event, "not this event", signal_id: Ecto.UUID.generate())

      assert {:error, :response_signal_mismatch} = finalize_run(run, final)
      assert_turn_remains_running(event)
    end

    test "rejects a failed Response without modifying Actor state" do
      %{agent: agent, event: event, run: run} = admit_event("failed-response")
      model_run = start_response(agent.uid, event)

      assert {:ok, failed} =
               ResponseCommit.commit_error(
                 model_run,
                 [],
                 %{"code" => "provider_failed", "message" => "provider failed"}
               )

      assert {:error, :final_response_not_terminal_success} = finalize_run(run, failed)
      assert_turn_remains_running(event)
    end

    test "rejects a generating Response without modifying Actor state" do
      %{agent: agent, event: event, run: run} =
        admit_event("generating-response")

      generating = start_response(agent.uid, event)

      assert {:error, :final_response_not_terminal_success} =
               finalize_run(run, generating)

      assert_turn_remains_running(event)
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
      assert %DateTime{} = Repo.get!(Signal, event.id).completed_at
    end

    test "iteration exhaustion is terminal and recorded in intent metadata" do
      %{agent: agent, event: event, run: run} =
        admit_event("iteration-exhausted")

      final = complete_response(agent.uid, event, "budget summary")

      assert {:ok,
              %{
                status: :completed,
                outcome: :iteration_exhausted,
                posted: %{intents: [%Intent{} = intent]}
              }} = finalize_run(run, final, :iteration_exhausted)

      assert intent.payload["metadata"]["turn_completion_outcome"] ==
               "iteration_exhausted"

      assert %DateTime{} = Repo.get!(Signal, event.id).completed_at
    end
  end

  test "ordinary appended input owns the preview and final reply after recovery" do
    %{agent: agent, event: event, run: run} = admit_event("appended-owner")
    assert :ok = Presentation.start(run, self())

    appended =
      for index <- 1..3 do
        {:ok, %{signal: next}} =
          emit_entry(
            agent.uid,
            event.reply_binding_name,
            group_entry(%{
              source_event_id: "appended-#{index}",
              provider_message_id: "appended-#{index}",
              provider_conversation_id:
                Repo.get_by!(PublicConversation, id: event.conversation_id).provider_conversation_id,
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

    generation =
      Ankole.Conversations.Delivery.PreviewState.get(Repo.reload!(last)).checkpoint[
        "owner_generation"
      ]

    assert [{pid, _}] = Preview.lookup(event.id)
    assert :sys.get_state(pid).signal.id == last.id
    monitor = Process.monitor(pid)
    assert :ok = Presentation.stop(run)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    run = %{run | steer_event_ids: Enum.map(appended, & &1.id)}

    {:ok, model} =
      start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
      })

    {:ok, final} =
      ResponseCommit.commit_complete(model, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => "All requirements are complete."}]
        }
      ])

    {:ok, replacement} = Admission.admit(run, Repo.reload!(event))
    {:ok, {:boundary, restored}} = Run.restore(replacement)
    assert :ok = Presentation.start(restored, self())
    assert [{recovered, _}] = Preview.lookup(event.id)
    assert :sys.get_state(recovered).signal.id == last.id

    assert Ankole.Conversations.Delivery.PreviewState.get(Repo.reload!(last)).checkpoint[
             "owner_generation"
           ] > generation

    assert {:ok, %{posted: %{intents: [box]}}} = Run.finalize(%{restored | anchor: final.id})
    assert box.source_signal_id == last.id
    assert box.reply_to_provider_message_id == last.provider_message_id
  end

  test "withdrawal committed before finalization prevents a reply and deletes the trigger" do
    %{agent: agent, event: event, run: run} = admit_event("withdrawn")
    final = complete_response(agent.uid, event, "must not be sent")

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(InputTombstone, :record, %{
                 conversation_id: event.conversation_id,
                 provider_message_id: event.provider_message_id,
                 tombstoned_until: DateTime.add(DateTime.utc_now(:microsecond), 1, :day)
               })
             end)

    assert {:error, :signal_canceled} = finalize_run(run, final)
    assert_turn_remains_running(event)

    {:ok, revision} =
      Repo.transact(fn repo ->
        Ankole.Signals.accept_in_tx(repo, %{
          producer: :kernel,
          target: %{agent_uid: agent.uid, session_id: event.session_id},
          source: "test:runtime",
          reply_route: %{binding_name: event.reply_binding_name},
          sender: agent.uid,
          id: "remove-#{event.id}",
          data: %{
            "revision" => %{
              "signal_id" => event.id,
              "kind" => "remove",
              "entry" => %{"provider_message_id" => event.provider_message_id}
            }
          },
          type: "input.revised",
          available_at: DateTime.utc_now(:microsecond),
          authorization: Ankole.Principals.WorkAccess.service()
        })
      end)

    assert {:ok, :stopped} = Revisions.apply(run, revision)
    refute Repo.get(Signal, event.id)
    assert %Signal{producer: :kernel, completed_at: %DateTime{}} = Repo.get!(Signal, revision.id)
    refute Repo.get_by(Intent, source_signal_id: event.id)
  end

  defp insert_fire_proof!(event) do
    now = DateTime.utc_now(:microsecond)

    {:ok, proof} =
      Repo.transact(fn ->
        with {:ok, proof} <-
               Ankole.Ash.create(Ankole.Schedule.Schemas.ScheduledEvent, :create_event, %{
                 kind: "cron_fire",
                 agent_uid: event.agent_uid,
                 session_id: event.session_id,
                 due_at: now,
                 requested_at: now,
                 timezone: "UTC",
                 idempotency_key: "presentation:#{event.id}"
               }) do
          Ankole.Ash.update(proof, :fire, %{signal_id: event.id, fired_at: now})
        end
      end)

    proof
  end

  defp admit_event(suffix) do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")

    assert {:ok, %{signal: event}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 source_event_id: "completion-#{suffix}",
                 provider_conversation_id: "mock:chat:completion-#{suffix}",
                 provider_message_id: "human-completion-#{suffix}",
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
             ResponseCommit.commit_complete(
               run,
               response_items,
               Keyword.get(opts, :terminal_metadata, %{})
             )

    final
  end

  defp start_response(subject_uid, event, opts \\ []) do
    conversation_key = Keyword.get(opts, :conversation_key, event.session_id)
    signal_id = Keyword.get(opts, :signal_id, event.id)
    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(subject_uid, conversation_key)

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
        metadata: %{"request_metadata" => %{"signal_id" => signal_id}}
      })

    run
  end

  defp finalize_run(run, final, outcome \\ :loop_finished) do
    Run.finalize(
      %{run | event: Repo.get!(Signal, run.signal_id), anchor: final.id},
      outcome
    )
  end

  defp assert_turn_remains_running(event) do
    assert %Signal{producer: :kernel, completed_at: nil, status: :running} =
             Repo.get!(Signal, event.id)

    refute Repo.exists?(from(entry in Intent, where: entry.source_signal_id == ^event.id))
  end
end
