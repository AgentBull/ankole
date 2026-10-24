defmodule Ankole.Sessions.SessionResetTest do
  use Ankole.SessionsCase

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Run
  alias Ankole.Schedule
  alias Ankole.Sessions.SessionReset

  setup {Ankole.SessionsCase, :use_mock_signal_provider_plugin}

  describe "session reset inputs" do
    test "daily reset enqueuer uses AppConfigure timezone and the 04:30 boundary" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset"

      assert {:ok, "Asia/Shanghai"} =
               Ankole.AppConfigure.put_tenant_by_key("system.timezone", "Asia/Shanghai")

      assert {:ok, _workspace} = Ankole.SessionsCase.ensure_workspace(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id)

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
                signals: [reset_event]
              }} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])

      assert DateTime.compare(boundary_at, ~U[2026-06-25 20:30:00Z]) == :eq
      assert reset_event.type == "session.reset_due"
      assert reset_event.session_id == session_id
      assert reset_event.data["reset"]["timezone"] == "Asia/Shanghai"
      assert reset_event.data["reset"]["local_time"] == "04:30"
      assert reset_event.data["reset"]["boundary_at"] == "2026-06-25T20:30:00Z"

      assert {:ok, %{signals: [same_reset_event]}} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:31:00.000000Z])

      assert same_reset_event.id == reset_event.id

      assert Repo.aggregate(
               from(input in Signal, where: input.type == "session.reset_due"),
               :count
             ) == 1
    end

    test "daily reset never enumerates BackgroundAgentJob execution sessions" do
      %{principal: agent} = Ankole.AIGatewayCase.background_agent_fixture()
      source = Ankole.WorkFixtures.service_source(agent.uid)

      assert {:ok, %{job: job}} =
               Ankole.BackgroundAgentJobs.create_with_dispatch(%{
                 "source_signal_id" => source.id,
                 "agent_uid" => agent.uid,
                 "owner_session_id" => source.session_id,
                 "source_tool_call_id" => "daily-reset-exclusion",
                 "title" => "Keep the Job session outside daily reset",
                 "task" => "Complete the background work.",
                 "reply_route" => %{"binding_name" => "control-plane:test"}
               })

      session_id = Ankole.BackgroundAgentJobs.job_session_id(job.id)

      assert {:ok, _workspace} = Ankole.SessionsCase.ensure_workspace(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert {:ok, %{due_sessions: 0, signals: []}} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])
    end

    test "daily reset never enumerates AIGateway conversations without actor session identity" do
      %{principal: agent} = agent_fixture()
      conversation_key = "stateful-responses-api:#{Ecto.UUID.generate()}"

      assert {:ok, conversation} =
               Ankole.AIGatewayCase.ensure_conversation(agent.uid, conversation_key)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert {:ok, %{due_sessions: 0, signals: []}} =
               SessionReset.enqueue_daily_session_resets(now: ~U[2026-06-25 20:30:30.000000Z])
    end

    test "EnqueueDailySessionResets Oban job appends due reset actor events" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset-job"

      assert {:ok, "Asia/Shanghai"} =
               Ankole.AppConfigure.put_tenant_by_key("system.timezone", "Asia/Shanghai")

      assert {:ok, _workspace} = Ankole.SessionsCase.ensure_workspace(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id)

      Repo.update_all(
        from(stored in Conversation, where: stored.id == ^conversation.id),
        set: [
          inserted_at: ~U[2026-06-25 20:00:00.000000Z],
          updated_at: ~U[2026-06-25 20:00:00.000000Z]
        ]
      )

      assert :ok =
               perform_job(Ankole.Sessions.Jobs.EnqueueDailySessionResets, %{})

      assert [
               %Signal{
                 producer: :kernel,
                 type: "session.reset_due",
                 session_id: ^session_id,
                 data: data
               }
             ] = Repo.all(from(event in Signal, where: event.type == "session.reset_due"))

      assert data["reset"]["timezone"] == "Asia/Shanghai"
      assert data["reset"]["local_time"] == "04:30"
    end

    test "daily reset enqueuer records the configured reset time in the event payload" do
      %{principal: agent} = agent_fixture()
      session_id = "manual-session:daily-reset-custom-time"

      assert {:ok, "Asia/Shanghai"} =
               Ankole.AppConfigure.put_tenant_by_key("system.timezone", "Asia/Shanghai")

      assert {:ok, _workspace} = Ankole.SessionsCase.ensure_workspace(agent.uid, session_id)

      assert {:ok, conversation} =
               Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id)

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
                signals: [reset_event]
              }} =
               SessionReset.enqueue_daily_session_resets(
                 now: ~U[2026-06-25 16:01:00.000000Z],
                 reset_time: ~T[00:00:00]
               )

      assert DateTime.compare(boundary_at, ~U[2026-06-25 16:00:00Z]) == :eq
      assert reset_event.data["reset"]["timezone"] == "Asia/Shanghai"
      assert reset_event.data["reset"]["local_time"] == "00:00"
      assert reset_event.data["reset"]["boundary_at"] == "2026-06-25T16:00:00Z"
    end

    test "completed reset makes a predecessor clarification callback stale without a successor turn" do
      %{principal: agent} = agent_fixture()
      %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-rich-provider")

      assert {:ok, %{signal: source_event}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "reset-clarification-source",
                   provider_conversation_id: "lark:chat:reset-clarification",
                   provider_message_id: "reset-clarification-message",
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

      assert {:ok, %{status: :completed, posted: %{intents: [clarify_intent]}}} =
               commit_turn_completion(
                 source_run,
                 "resp_#{response.id}",
                 :loop_finished
               )

      assert clarify_intent.payload["metadata"]["source"] == "ai_gateway_clarify"

      card_message_id = "clarification-card-before-reset"

      assert {:ok, %{status: :sent}} =
               Ankole.Conversations.Delivery.dispatch(
                 clarify_intent.agent_uid,
                 clarify_intent.binding_name,
                 clarify_intent.outbound_key,
                 delivery_adapter([:post_entry, :reply_entry, :edit_entry], fn _intent ->
                   {:ok, %{created_provider_message_id: card_message_id}}
                 end),
                 now: DateTime.add(@base_time, 2, :second)
               )

      adapter_checkpoint =
        source_event.id
        |> then(
          &Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, &1)).checkpoint
        )
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
               PreviewStates.put_checkpoint(
                 source_event.id,
                 adapter_checkpoint
               )

      assert :ok =
               PreviewStates.record_provider_message(
                 source_event.id,
                 card_message_id
               )

      pending_checkpoint =
        Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

      assert pending_checkpoint["interactions"]["clarify:call-reset-audience"]["state"] ==
               "pending"

      assert {:ok, reset_event} =
               append_runtime_signal(agent.uid, source_event.session_id, "session.reset_due",
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint[
               "interactions"
             ][
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

      resolved_checkpoint =
        Ankole.Conversations.Delivery.PreviewStates.get(Repo.get!(Signal, source_event.id)).checkpoint

      interaction = resolved_checkpoint["interactions"]["clarify:call-reset-audience"]
      assert interaction["state"] == "superseded"
      assert interaction["superseded_by_signal_id"] == reset_event.id
      assert resolved_checkpoint["presentation"]["interaction_status"] == "superseded"
      assert Enum.all?(resolved_checkpoint["presentation"]["actions"], & &1["disabled"])
      assert resolved_checkpoint["refresh_pending"]

      assert {:ok, %{status: :stale_action}} =
               Observe.emit_action(
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
               from(event in Signal,
                 where: event.agent_uid == ^agent.uid and event.type == "signal.action.invoked"
               )
             )

      assert {:ok, :idle} = Run.rebuild(key(reset_event))
    end

    test "session reset_due waits for running work and preserves queued cron work" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")

      assert {:ok, %{signal: first_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-reset-before",
                   provider_conversation_id: "lark:chat:reset-barrier",
                   provider_message_id: "msg-reset-before",
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
               append_runtime_signal(agent.uid, session_id, "session.reset_due",
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
                         "conversation_id" => first_input.conversation_id,
                         "provider_thread_id" => "thread-reset-barrier"
                       }
                     ]
                   },
                   "idempotency_key" => "reset-boundary-cron"
                 },
                 now: DateTime.add(@base_time, 1, :second),
                 created_by: %{"signal_id" => first_input.id}
               )

      execution_actor = %{
        agent_uid: agent.uid,
        session_id: Schedule.cron_execution_session_id(cron_schedule.id)
      }

      assert Schedule.list_cron_runs(cron_schedule.id, 10) == []
      assert cron_schedule.next_fire_at == first_cron_slot

      assert {:ok, %{signal: cron_input}} =
               Ankole.Schedule.fire_cron(cron_schedule.id, now: first_cron_slot)

      assert cron_input.session_id == execution_actor.session_id

      assert {:ok, _} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: cron_input.human_uid,
                 resource_pattern: "agent:#{agent.uid}:tool:finish_scheduled",
                 action: "invoke"
               })

      assert {:ok, %{signal: later_input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{
                   source_event_id: "evt-reset-after",
                   provider_conversation_id: "lark:chat:reset-barrier",
                   provider_message_id: "msg-reset-after",
                   provider_thread_id: "thread-reset-barrier",
                   text: "new day work",
                   explicit: true,
                   provider_time: DateTime.add(@base_time, 2, :second)
                 }),
                 now: DateTime.add(@base_time, 2, :second)
               )

      refute Ankole.Sessions.Commands.injectable?(reset_event)
      assert Queue.next_ready_event(agent.uid, session_id).id == first_input.id

      assert Repo.get!(Signal, reset_event.id).status == :queued
      assert Repo.get!(Signal, later_input.id).status == :queued

      assert {:ok, cron_run} =
               Admission.admit(execution_actor, cron_input,
                 now: DateTime.add(@base_time, 3, :second)
               )

      cron_conversation = cron_run.conversation
      assert cron_conversation.conversation_key == execution_actor.session_id
      assert cron_conversation.id != first_conversation.id

      assert {:ok, {:preparing, cron_run}} = Ankole.Sessions.Model.prepare(cron_run)

      call = %{
        "type" => "function_call",
        "name" => "finish_scheduled",
        "call_id" => Ecto.UUID.generate(),
        "arguments" =>
          Ankole.JSON.encode!(%{"outcome" => "reply", "reply" => "scheduled work completed"})
      }

      committed = complete_aigateway_turn!(cron_run, nil, output_items: [call])
      cron_run = %{cron_run | model_response: committed, calls: [call], round_calls: [call]}
      assert {:ok, tool, args} = Ankole.Sessions.Tools.prepare(cron_run, call)
      result = Ankole.Sessions.Tools.execute(cron_run, call, tool, args)
      refute result.is_error

      assert {:ok, journal} =
               Run.record_round(%{cron_run | results: %{call["call_id"] => result}})

      assert {:ok, {_state, cron_run}} = Run.restore(cron_run)

      assert {:ok, %{status: :completed}} =
               commit_turn_completion(cron_run, "resp_#{journal.message.id}", :loop_finished)

      assert %DateTime{} = Repo.get!(Signal, cron_input.id).completed_at

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
      assert Repo.get(Signal, reset_event.id)
      assert Repo.get!(Signal, later_input.id).status == :queued

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
      provider_conversation_id:
        Repo.get_by!(Ankole.Conversations.Conversation, id: source_event.conversation_id).provider_conversation_id,
      provider_message_id: card_message_id,
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
          "sourceSignalId" => source_event.id
        }
      }
    }
  end
end
