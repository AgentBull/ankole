defmodule Ankole.SignalsGateway.ActorRuntime.SessionResetTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.Conversations.{Admission, Run}
  alias Ankole.Schedule
  alias Ankole.SignalsGateway.ActorRuntime.SessionReset
  alias Ankole.SignalsGateway.ActorRuntime.SessionWorkspaces

  setup {Ankole.SignalsGateway.ActorRuntimeCase, :use_mock_signal_provider_plugin}

  describe "session reset inputs" do
    test "daily reset enqueuer uses AppConfigure timezone and the 04:30 boundary" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset"

      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")
      assert {:ok, _workspace} = SessionWorkspaces.ensure(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert {:ok,
              %{
                status: :enqueued,
                boundary_at: boundary_at,
                timezone: "Asia/Shanghai",
                due_sessions: 1,
                actor_events: [reset_event]
              }} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])

      assert DateTime.compare(boundary_at, ~U[2026-06-25 20:30:00Z]) == :eq
      assert reset_event.type == "session.reset_due"
      assert reset_event.session_id == session_id
      assert reset_event.payload["data"]["reset"]["timezone"] == "Asia/Shanghai"
      assert reset_event.payload["data"]["reset"]["local_time"] == "04:30"
      assert reset_event.payload["data"]["reset"]["boundary_at"] == "2026-06-25T20:30:00Z"

      assert {:ok, %{actor_events: [same_reset_event]}} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:31:00.000000Z])

      assert same_reset_event.id == reset_event.id

      assert Repo.aggregate(
               from(input in ActorEvent, where: input.type == "session.reset_due"),
               :count
             ) == 1
    end

    test "daily reset never enumerates BackgroundAgentJob execution sessions" do
      %{principal: agent} = agent_fixture()
      session_id = Ankole.BackgroundAgentJobs.job_session_id(1000)

      assert {:ok, _workspace} = SessionWorkspaces.ensure(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(
                 agent.uid,
                 session_id
               )

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert {:ok, %{due_sessions: 0, actor_events: []}} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])
    end

    test "daily reset never enumerates AIGateway conversations without actor session identity" do
      %{principal: agent} = agent_fixture()
      conversation_key = "stateful-responses-api:#{Ecto.UUID.generate()}"

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, conversation_key)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert {:ok, %{due_sessions: 0, actor_events: []}} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])
    end

    test "EnqueueDailySessionResets Oban job appends due reset actor events" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset-job"

      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")
      assert {:ok, _workspace} = SessionWorkspaces.ensure(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert :ok =
               perform_job(Ankole.SignalsGateway.ActorRuntime.Jobs.EnqueueDailySessionResets, %{})

      assert [
               %ActorEvent{
                 type: "session.reset_due",
                 session_id: ^session_id,
                 payload: payload
               }
             ] = Repo.all(from(event in ActorEvent, where: event.type == "session.reset_due"))

      assert payload["data"]["reset"]["timezone"] == "Asia/Shanghai"
      assert payload["data"]["reset"]["local_time"] == "04:30"
    end

    test "daily reset enqueuer records the configured reset time in the event payload" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset-custom-time"

      assert {:ok, "Asia/Shanghai"} = SystemConfig.put_timezone("Asia/Shanghai")
      assert {:ok, _workspace} = SessionWorkspaces.ensure(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGateway.Conversations.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 15:00:00.000000Z],
          updated_at: ~U[2026-06-25 15:00:00.000000Z]
        ]
      )

      assert {:ok,
              %{
                status: :enqueued,
                boundary_at: boundary_at,
                timezone: "Asia/Shanghai",
                actor_events: [reset_event]
              }} =
               SessionReset.enqueue_daily_session_resets(
                 now: ~U[2026-06-25 16:01:00.000000Z],
                 reset_time: ~T[00:00:00]
               )

      assert DateTime.compare(boundary_at, ~U[2026-06-25 16:00:00Z]) == :eq
      assert reset_event.payload["data"]["reset"]["timezone"] == "Asia/Shanghai"
      assert reset_event.payload["data"]["reset"]["local_time"] == "00:00"
      assert reset_event.payload["data"]["reset"]["boundary_at"] == "2026-06-25T16:00:00Z"
    end

    test "completed reset makes a predecessor clarification callback stale without a successor turn" do
      %{principal: agent} = agent_fixture()
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-rich-provider")

      assert {:ok, %{actor_event: source_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "reset-clarification-source",
                   signal_channel_id: "lark:chat:reset-clarification",
                   source_entry_id: "reset-clarification-message",
                   provider_thread_id: "thread-reset-clarification",
                   text: "Prepare the report.",
                   explicit: true
                 }),
                 now: @base_time
               )

      assert {:ok, source_run} = Admission.admit(key(source_event), source_event, now: @base_time)
      predecessor_conversation = source_run.conversation

      response =
        complete_aigateway_turn!(source_run, "",
          request_items: [
            %{
              "type" => "message",
              "role" => "user",
              "content" => [%{"type" => "input_text", "text" => "Prepare the report."}]
            }
          ],
          output_items: [
            %{
              "type" => "function_call",
              "call_id" => "call-reset-audience",
              "name" => "clarify",
              "arguments" => "{}"
            },
            %{
              "type" => "function_call_output",
              "call_id" => "call-reset-audience",
              "output" => %{
                "tool" => "clarify",
                "ok" => true,
                "question" => "Who should receive the report?",
                "choices" => [
                  %{"label" => "Operators"},
                  %{"label" => "Executives"}
                ]
              }
            }
          ]
        )

      assert {:ok, %{status: :completed, outboxes: %{clarify: clarify_outbox}}} =
               commit_turn_completion(
                 source_run,
                 "resp_#{response.id}",
                 "loop_finished"
               )

      assert clarify_outbox.payload["metadata"]["source"] == "ai_gateway_clarify"

      card_message_id = "clarification-card-before-reset"

      assert {:ok, %{status: :succeeded}} =
               SignalsGateway.dispatch_outbox(
                 clarify_outbox.agent_uid,
                 clarify_outbox.binding_name,
                 clarify_outbox.outbound_key,
                 outbox_adapter([:post_entry, :reply_entry, :edit_entry], fn _outbox ->
                   {:ok, %{created_source_entry_id: card_message_id}}
                 end),
                 now: DateTime.add(@base_time, 2, :second)
               )

      adapter_checkpoint =
        source_event.id
        |> then(&Repo.get!(ActorEvent, &1).reply_preview_checkpoint)
        |> Map.merge(%{
          "card_id" => "card-before-reset",
          "message_id" => card_message_id,
          "streaming_state" => "closed",
          "cards" => [
            %{
              "index" => 0,
              "card_id" => "card-before-reset",
              "message_id" => card_message_id,
              "state" => "open"
            }
          ]
        })

      assert {:ok, _event} =
               Actors.put_reply_preview_checkpoint(source_event.id, adapter_checkpoint)

      assert :ok =
               Actors.record_reply_preview_source_entry(source_event.id, card_message_id)

      pending_checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint

      assert pending_checkpoint["interactions"]["clarify:call-reset-audience"]["state"] ==
               "pending"

      assert {:ok, reset_event} =
               append_runtime_actor_event(agent.uid, source_event.session_id, "session.reset_due",
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint["interactions"][
               "clarify:call-reset-audience"
             ]["state"] == "pending"

      assert {:ok,
              %{
                status: :session_reset,
                closed_conversation: closed_conversation,
                conversation: successor_conversation,
                superseded_reply_interactions: 1
              }} =
               SessionReset.process_due(key(reset_event), reset_event,
                 now: DateTime.add(@base_time, 4, :second)
               )

      assert closed_conversation.id == predecessor_conversation.id
      assert successor_conversation.id != predecessor_conversation.id

      resolved_checkpoint = Repo.get!(ActorEvent, source_event.id).reply_preview_checkpoint
      interaction = resolved_checkpoint["interactions"]["clarify:call-reset-audience"]
      assert interaction["state"] == "superseded"
      assert interaction["superseded_by_actor_event_id"] == reset_event.id
      assert resolved_checkpoint["presentation"]["interaction_status"] == "superseded"
      assert Enum.all?(resolved_checkpoint["presentation"]["actions"], & &1["disabled"])
      assert resolved_checkpoint["refresh_pending"]

      assert {:ok, %{status: :stale_action}} =
               Ingress.emit_action(
                 agent.uid,
                 "bot",
                 clarification_action_input(
                   source_event,
                   human.uid,
                   card_message_id,
                   "callback-after-reset"
                 ),
                 now: DateTime.add(@base_time, 5, :second)
               )

      refute Repo.exists?(
               from(event in ActorEvent,
                 where: event.agent_uid == ^agent.uid and event.type == "signal.action.invoked"
               )
             )

      assert {:ok, :idle} = Run.rebuild(key(reset_event))
    end

    test "session reset_due waits for running work and preserves queued cron work" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

      assert {:ok, %{actor_event: first_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-reset-before",
                   signal_channel_id: "lark:chat:reset-barrier",
                   source_entry_id: "msg-reset-before",
                   provider_thread_id: "thread-reset-barrier",
                   text: "finish this first",
                   explicit: true
                 }),
                 now: @base_time
               )

      assert {:ok, first_run} = Admission.admit(key(first_input), first_input, now: @base_time)
      first_conversation = first_run.conversation
      generating = start_aigateway_run_for_turn!(first_run)

      session_id = first_input.session_id
      channel_actor = %{agent_uid: agent.uid, session_id: session_id}

      assert {:ok, reset_event} =
               append_runtime_actor_event(agent.uid, session_id, "session.reset_due",
                 now: DateTime.add(@base_time, 2, :second)
               )

      first_cron_slot = DateTime.add(@base_time, 2, :second)

      assert {:ok, %{cron_schedule: cron_schedule}} =
               Schedule.create_cron_schedule(
                 %{
                   "agent_uid" => agent.uid,
                   "owner_session_id" => session_id,
                   "binding_name" => "bot",
                   "name" => "reset-boundary-cron",
                   "schedule" => %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_cron_slot)
                   },
                   "payload" => %{"task" => "continue after reset"},
                   "delivery" => %{
                     "targets" => [
                       %{
                         "binding_name" => "bot",
                         "signal_channel_id" => "lark:chat:reset-barrier",
                         "provider_thread_id" => "thread-reset-barrier"
                       }
                     ]
                   },
                   "idempotency_key" => "reset-boundary-cron"
                 },
                 now: DateTime.add(@base_time, 1, :second),
                 created_by: %{"actor_event_id" => first_input.id}
               )

      execution_actor = %{
        agent_uid: agent.uid,
        session_id: Schedule.cron_execution_session_id(cron_schedule.id)
      }

      assert Schedule.list_cron_runs(cron_schedule.id, 10) == []
      assert cron_schedule.next_fire_at == first_cron_slot

      assert {:ok, %{actor_event: cron_input}} =
               Repo.transact(fn _repo ->
                 Ankole.Schedule.Fire.fire_cron(cron_schedule.id, now: first_cron_slot)
               end)

      assert cron_input.session_id == execution_actor.session_id

      assert {:ok, %{actor_event: later_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-reset-after",
                   signal_channel_id: "lark:chat:reset-barrier",
                   source_entry_id: "msg-reset-after",
                   provider_thread_id: "thread-reset-barrier",
                   text: "new day work",
                   explicit: true,
                   provider_time: DateTime.add(@base_time, 2, :second)
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      refute Ankole.Conversations.Commands.injectable?(reset_event)
      assert Actors.next_ready_event(agent.uid, session_id).id == first_input.id

      assert Repo.get!(ActorEvent, reset_event.id).input_state == "open"
      assert Repo.get!(ActorEvent, later_input.id).input_state == "open"

      assert {:ok, cron_run} =
               Admission.admit(execution_actor, cron_input,
                 now: DateTime.add(@base_time, 3, :second)
               )

      cron_conversation = cron_run.conversation
      assert cron_conversation.conversation_key == execution_actor.session_id
      assert cron_conversation.id != first_conversation.id

      committed =
        complete_aigateway_turn!(
          cron_run,
          Ankole.JSON.encode!(%{"outcome" => "reply", "reply" => "scheduled work completed"})
        )

      assert {:ok, %{status: :completed}} =
               commit_turn_completion(cron_run, "resp_#{committed.id}", "loop_finished")

      assert %DateTime{} = Repo.get!(ActorEvent, cron_input.id).completed_at

      completed = complete_aigateway_turn!(first_run, "done", run: generating)
      assert {:ok, _} = Run.finalize(%{first_run | anchor: completed.id})

      assert {:ok,
              %{
                status: :session_reset,
                closed_conversation: closed_conversation,
                conversation: next_conversation
              }} =
               SessionReset.process_due(channel_actor, reset_event,
                 now: DateTime.add(@base_time, 4, :second)
               )

      assert closed_conversation.id == first_conversation.id
      assert next_conversation.id != closed_conversation.id
      assert Repo.get!(Conversation, first_conversation.id).ended_at
      assert Repo.get(ActorEvent, reset_event.id)
      assert Repo.get!(ActorEvent, later_input.id).input_state == "open"

      # The channel reset never touched the execution session's conversation.
      assert Repo.get!(Conversation, cron_conversation.id).ended_at == nil

      assert {:ok, later_run} =
               Admission.admit(channel_actor, later_input,
                 now: DateTime.add(@base_time, 6, :second)
               )

      assert later_run.conversation.id == next_conversation.id
    end
  end

  defp key(event), do: %{agent_uid: event.agent_uid, session_id: event.session_id}

  defp clarification_action_input(source_event, principal_uid, card_message_id, source_event_id) do
    %{
      source_event_id: source_event_id,
      action_id: source_event_id,
      signal_channel_id: source_event.signal_channel_id,
      source_entry_id: card_message_id,
      provider_thread_id: source_event.provider_thread_id,
      action: %{
        "name" => "clarify-choice",
        "operator_principal_uid" => principal_uid,
        "value" => %{
          "version" => "ankole.interactive_output.action.v1",
          "answerKind" => "choice",
          "interactionId" => "clarify:call-reset-audience",
          "interactionVersion" => 1,
          "controlId" => "clarify-choice",
          "selectedOptionId" => "operators",
          "optionValue" => "Operators",
          "sourceActorEventId" => source_event.id
        }
      }
    }
  end
end
