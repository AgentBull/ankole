defmodule Ankole.ScheduleTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.DataCase, async: false

  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.Context
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.ToolCatalog
  alias Ankole.Sessions.Tools

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Signals.Signal
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.PluginFixtures.MockSignalProvider.Inbound, as: MockInbound
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Conversations.InboundBatch
  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.Intent

  import Ankole.SessionsCase,
    only: [complete_signal: 4, wait_for_final_mirror: 1]

  import Ankole.SignalsFixtures, only: [delivery_adapter: 2]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  @base_time DateTime.utc_now(:microsecond)

  setup :use_mock_signal_provider_plugin

  describe "durable schedule domain" do
    test "resuming a schedule retains its pending job after the old uniqueness window" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "old-pending-job",
                   idempotency_key: "old-pending-job",
                   schedule: every_schedule(DateTime.add(@base_time, 3600, :second))
                 ),
                 now: @base_time
               )

      job = cron_job(schedule.id)

      from(j in Oban.Job, where: j.id == ^job.id)
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(), -120, :second)])

      assert {:ok, _} = Schedule.pause_cron_schedule(schedule.id, now: @base_time)
      assert {:ok, _} = Schedule.resume_cron_schedule(schedule.id, now: @base_time)
      assert cron_job(schedule.id).id == job.id
      assert cron_job(schedule.id).attempt == 0
    end

    test "model projections reduce operator errors to stable schedule reasons" do
      internal_id = "019f0000-0000-7000-8000-000000000001"

      event = %ScheduledEvent{
        id: 1000,
        kind: "check_back_later",
        status: :failed,
        wake_payload: %{},
        last_fire_error: %{
          "reason" => "provider request #{internal_id} failed",
          "signal_id" => internal_id
        }
      }

      projection = Schedule.event_model_projection(event)

      assert projection["last_error"] == %{"reason" => "schedule_fire_failed"}
      refute inspect(projection) =~ internal_id

      known = %{event | last_fire_error: %{"reason" => ":cron_schedule_not_active"}}

      assert Schedule.event_model_projection(known)["last_error"] == %{
               "reason" => "cron_schedule_not_active"
             }
    end

    test "check_back_later creates one wake edge and fires one signal idempotently" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      attrs =
        checkback_attrs(agent.uid,
          schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
        )

      assert {:ok, %{status: :scheduled, scheduled_event: event}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert event.due_at == due_at
      assert event.provider_message_id == "msg-source"
      assert event.wake_payload["quiet_success"] == false

      assert {:ok, %{status: :already_scheduled, scheduled_event: duplicate}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert duplicate.id == event.id

      assert {:ok, %{status: :fired, signal: input}} =
               Schedule.fire_due_event(event.id, now: due_at)

      assert input.type == "check_back_later.wakeup"
      assert input.source_event_id == "check_back_later:#{event.id}:wakeup"
      assert get_in(input.data, ["wake_payload", "check"]) == "Check the incident."

      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: due_at)
      assert Repo.aggregate(from(e in Signal, where: e.type != "test.work"), :count) == 1
    end

    test "updating a checkback preserves its id and due time while replacing wake instructions" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      attrs =
        checkback_attrs(agent.uid,
          check: "Write a professional PDF, preferably 6–12 pages.",
          schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
        )

      assert {:ok, %{scheduled_event: original}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      updates =
        agent.uid
        |> checkback_attrs(
          tool_call_id: "tool-check-update-1",
          idempotency_key: "checkback-update-1",
          check: "Let the evidence determine the PDF length.",
          context_summary: "The user removed the page constraint."
        )
        |> Map.delete("schedule")

      assert {:ok, %{status: :updated, scheduled_event: updated}} =
               Schedule.update_checkback(original.id, updates,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert updated.id == original.id
      assert updated.due_at == due_at
      assert updated.wake_payload["check"] == "Let the evidence determine the PDF length."
      assert updated.wake_payload["context_summary"] == "The user removed the page constraint."
      assert updated.idempotency_key == original.idempotency_key
      assert updated.source_provenance == original.source_provenance
      assert updated.tool_call_id == original.tool_call_id

      assert {:ok, %{status: :updated, scheduled_event: retried}} =
               Schedule.update_checkback(original.id, updates,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert retried.id == original.id
      assert retried.wake_payload == updated.wake_payload

      assert {:ok, %{status: :already_scheduled, scheduled_event: duplicate}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert duplicate.id == original.id

      assert {:ok, %{status: :fired, signal: wakeup}} =
               Schedule.fire_due_event(original.id, now: due_at)

      assert get_in(wakeup.data, ["wake_payload", "check"]) ==
               "Let the evidence determine the PDF length."

      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(original.id, now: due_at)
      assert Repo.aggregate(from(e in Signal, where: e.type != "test.work"), :count) == 1
    end

    test "successive updates and cancellation keep one checkback id" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: original}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      for {check, index} <-
            Enum.with_index(["Use the first correction.", "Use the latest correction."]) do
        attrs =
          agent.uid
          |> checkback_attrs(
            tool_call_id: "tool-check-update-#{index}",
            idempotency_key: "checkback-update-#{index}",
            check: check
          )
          |> Map.delete("schedule")

        assert {:ok, %{scheduled_event: current}} =
                 Schedule.update_checkback(original.id, attrs,
                   now: DateTime.add(@base_time, index + 1, :second)
                 )

        assert current.id == original.id
        assert current.wake_payload["check"] == check
      end

      assert {:ok, cancelled} =
               Schedule.cancel_checkback(original.id, now: DateTime.add(@base_time, 3, :second))

      assert cancelled.id == original.id
      assert cancelled.status == :cancelled
      assert {:ok, repeated} = Schedule.cancel_checkback(original.id, now: @base_time)
      assert_persisted_equal(repeated, cancelled)
      assert Schedule.list_pending_checkbacks(agent.uid, original.session_id) == []
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(original.id, now: due_at)
      assert Repo.aggregate(from(e in Signal, where: e.type != "test.work"), :count) == 0
    end

    test "a checkback replaced by an earlier version returns checkback_replaced" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      attrs = checkback_attrs(agent.uid, [])

      assert {:ok, %{scheduled_event: previous}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert {:ok, replacement} =
               Repo.transact(fn ->
                 attrs =
                   previous
                   |> Map.from_struct()
                   |> Map.take(Ash.Resource.Info.action(ScheduledEvent, :create_event).accept)
                   |> Map.put(:idempotency_key, previous.idempotency_key <> ":replacement")
                   |> Map.put(:source_provenance, %{"replaces_scheduled_event_id" => previous.id})

                 Ankole.Ash.create(ScheduledEvent, :create_event, attrs)
               end)

      assert {:ok, _cancelled} =
               Repo.transact(fn ->
                 Ankole.Ash.update(previous, :cancel, %{
                   cancelled_at: @base_time,
                   last_fire_error: %{
                     "reason" => "checkback_replaced",
                     "replacement_scheduled_event_id" => replacement.id
                   }
                 })
               end)

      assert {:error, :checkback_replaced} = Schedule.get_checkback(previous.id)

      assert {:error, :checkback_replaced} =
               Schedule.update_checkback(previous.id, attrs, now: @base_time)

      assert {:error, :checkback_replaced} =
               Schedule.cancel_checkback(previous.id, now: @base_time)

      assert Repo.get!(ScheduledEvent, replacement.id).status == :scheduled
    end

    test "an update while the wake job executes leaves one fire" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      # Oban compares due_at with its real insertion clock.
      now = DateTime.utc_now(:microsecond)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(checkback_attrs(agent.uid, []), now: now)

      jobs =
        from(j in Oban.Job,
          where:
            j.worker == "Ankole.Sessions.Jobs.FireScheduledEvent" and
              fragment("?->>'scheduled_event_id' = ?", j.args, ^Integer.to_string(event.id))
        )

      assert {1, _} = Repo.update_all(jobs, set: [state: "executing"])
      due_at = DateTime.add(event.due_at, 5, :minute)

      attrs =
        checkback_attrs(agent.uid,
          schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
        )

      assert {:ok, %{scheduled_event: updated}} =
               Schedule.update_checkback(event.id, attrs, now: now)

      assert updated.id == event.id
      assert Enum.sort(Repo.all(from(j in jobs, select: j.state))) == ["executing", "scheduled"]
      assert {:ok, %{status: :fired}} = Schedule.fire_due_event(event.id, now: due_at)
      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: due_at)
      assert Repo.aggregate(from(e in Signal, where: e.type != "test.work"), :count) == 1
    end

    test "fire failures persist diagnostics and mark final attempt failed" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{status: :scheduled, scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      ScheduledEvent
      |> where([scheduled_event], scheduled_event.id == ^event.id)
      |> Repo.update_all(set: [session_id: ""])

      assert {:error, :invalid_signal_target} =
               Schedule.fire_due_event(event.id, now: due_at, attempt: 3, max_attempts: 10)

      retried = Repo.get!(ScheduledEvent, event.id)
      assert retried.status == :scheduled
      assert retried.last_fire_error["reason"] =~ "invalid_signal_target"

      assert {:error, :invalid_signal_target} =
               Schedule.fire_due_event(event.id, now: due_at, attempt: 10, max_attempts: 10)

      failed = Repo.get!(ScheduledEvent, event.id)
      assert failed.status == :failed
      assert failed.last_fire_error["reason"] =~ "invalid_signal_target"
    end

    test "FireScheduledEvent Oban job fires a due scheduled event" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(DateTime.utc_now(:microsecond), -60, :second)

      assert {:ok, %{status: :scheduled, scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   idempotency_key: "checkback-oban-fire",
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: DateTime.add(due_at, -60, :second)
               )

      assert :ok =
               perform_job(Ankole.Sessions.Jobs.FireScheduledEvent, %{
                 "scheduled_event_id" => event.id
               })

      fired = Repo.get!(ScheduledEvent, event.id)
      assert fired.status == :fired
      assert %DateTime{} = fired.fired_at

      assert %Signal{type: "check_back_later.wakeup"} =
               Repo.get!(Signal, fired.signal_id)
    end

    test "a slot history rejects a second automatic Signal" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: rule}} =
               create_cron_schedule(cron_attrs(agent.uid, schedule: every_schedule(slot)),
                 now: @base_time
               )

      assert {:ok, %{signal: event}} = Schedule.fire_cron(rule.id, now: slot)
      Repo.update!(Ecto.Changeset.change(Repo.reload!(rule), next_fire_at: slot))
      assert {:error, %Ash.Error.Invalid{errors: errors}} = Schedule.fire_cron(rule.id, now: slot)

      assert Enum.any?(errors, fn error ->
               error.field == :cron_schedule_id and
                 error.private_vars[:constraint] == "scheduled_events_cron_slot_index" and
                 error.private_vars[:constraint_type] == :unique
             end)

      assert Repo.aggregate(
               from(e in Signal, where: e.source_event_id == ^event.source_event_id),
               :count
             ) == 1

      assert [_history] = Schedule.list_cron_runs(rule.id)
    end

    test "a rejected legacy cron attempt can record cancellation for a consumed slot" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: rule}} =
               create_cron_schedule(cron_attrs(agent.uid, schedule: every_schedule(slot)),
                 now: @base_time
               )

      assert {:ok, %{signal: signal}} = Schedule.fire_cron(rule.id, now: slot)

      CronSchedule
      |> where([schedule], schedule.id == ^rule.id)
      |> Repo.update_all(set: [payload: %{}, next_fire_at: slot])

      assert {:ok, %{status: :cancelled, scheduled_event: cancelled}} =
               Schedule.fire_cron(rule.id, now: slot)

      assert cancelled.status == :cancelled
      assert cancelled.cron_fire_slot_at == slot
      assert cancelled.cancelled_at == slot
      assert cancelled.last_fire_error == %{"reason" => ":cron_task_required"}

      assert Enum.sort(Enum.map(Schedule.list_cron_runs(rule.id), & &1.status)) == [
               :cancelled,
               :fired
             ]

      assert Repo.aggregate(
               from(event in Signal, where: event.source_event_id == ^signal.source_event_id),
               :count
             ) == 1
    end

    test "an executing cron wakeup can update its rule without a second slot fire" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: rule}} =
               create_cron_schedule(cron_attrs(agent.uid, schedule: every_schedule(slot)),
                 now: @base_time
               )

      old = cron_job(rule.id)
      Repo.update!(Ecto.Changeset.change(old, state: "executing"))

      assert {:ok, _} =
               Schedule.update_cron_schedule(rule.id, %{"payload" => %{"task" => "updated"}},
                 now: @base_time
               )

      pending = cron_job(rule.id)
      assert pending.id != old.id
      assert pending.scheduled_at == slot
      assert {:ok, %{signal: event}} = Schedule.fire_cron(rule.id, now: slot)
      assert {:ok, %{status: :noop}} = Schedule.fire_cron(rule.id, now: slot)
      assert cron_job(rule.id).scheduled_at == DateTime.add(slot, 1, :minute)

      assert Repo.aggregate(
               from(e in Signal, where: e.source_event_id == ^event.source_event_id),
               :count
             ) == 1
    end

    test "a future cron wakeup restores a missing job and does not create history" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: rule}} =
               create_cron_schedule(cron_attrs(agent.uid, schedule: every_schedule(slot)),
                 now: @base_time
               )

      Repo.delete!(cron_job(rule.id))
      assert {:ok, %{status: :noop}} = Schedule.fire_cron(rule.id, now: @base_time)
      assert cron_job(rule.id).scheduled_at == slot
      assert Schedule.list_cron_runs(rule.id) == []
    end

    test "a review-required cron rule cannot produce work" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: rule}} =
               create_cron_schedule(cron_attrs(agent.uid, schedule: every_schedule(slot)),
                 now: @base_time
               )

      Repo.update!(Ecto.Changeset.change(rule, authorization_kind: "review_required"))

      assert {:error, :work_authorization_review_required} =
               Schedule.fire_cron(rule.id, now: slot)

      assert Schedule.list_cron_runs(rule.id) == []
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "a cron rule cannot renew a revoked Human authorization" do
      {rule, human} = human_cron_rule()

      assert {:ok, disabled} =
               Ankole.Principals.HumanAccess.disable(human.uid, "Offboarding", nil, "disable")

      assert disabled.access_version > rule.human_access_version
      assert {:error, :human_access_revoked} = Schedule.fire_cron(rule.id, now: rule.next_fire_at)
      assert Schedule.list_cron_runs(rule.id) == []
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "automatic cron history and Signal retain the rule Human authorization" do
      {rule, _human} = human_cron_rule()

      assert {:ok, %{scheduled_event: history, signal: event}} =
               Schedule.fire_cron(rule.id, now: rule.next_fire_at)

      assert Ankole.Principals.WorkAccess.fields(history) ==
               Ankole.Principals.WorkAccess.fields(rule)

      assert Ankole.Principals.WorkAccess.fields(event) ==
               Ankole.Principals.WorkAccess.fields(rule)
    end

    test "a service cron rule admits one automatic fire" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: rule}} =
               create_cron_schedule(cron_attrs(agent.uid, []), now: @base_time)

      assert rule.authorization_kind == "service"
      assert {:ok, %{signal: event}} = Schedule.fire_cron(rule.id, now: rule.next_fire_at)
      assert event.authorization_kind == "service"
    end

    test "a suspended tenant cannot admit an automatic cron fire", %{tenant: tenant} do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: rule}} =
               create_cron_schedule(cron_attrs(agent.uid, []), now: @base_time)

      Repo.update!(Ecto.Changeset.change(tenant, suspended_at: @base_time))
      assert {:error, :tenant_suspended} = Schedule.fire_cron(rule.id, now: rule.next_fire_at)
      assert Schedule.list_cron_runs(rule.id) == []
      assert Repo.aggregate(Signal, :count) == 0
    end

    test "cron fire coalesces missed backlog and carries configured delivery route" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      late_fire = DateTime.add(@base_time, 10, :minute)
      origin_ai_message = ai_message_fixture(agent.uid)

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time,
                 created_by: %{
                   "kind" => "test",
                   "principal_uid" => to_string(Ankole.ActorRef.from_principal(agent)),
                   "origin_ai_message_id" => origin_ai_message.id
                 }
               )

      assert Schedule.list_cron_runs(schedule.id, 10) == []

      assert schedule.delivery == %{
               "targets" => [
                 %{
                   "binding_name" => "bot",
                   "conversation_id" => public_conversation_id("mock:chat:schedule"),
                   "provider_thread_id" => "thread-schedule"
                 }
               ]
             }

      assert {:ok, %{status: :fired, signal: input, scheduled_event: event}} =
               Schedule.fire_cron(schedule.id, now: late_fire)

      assert event.due_at == first_slot
      assert event.conversation_id == public_conversation_id("mock:chat:schedule")
      assert event.provider_thread_id == "thread-schedule"
      assert event.origin_ai_message_id == origin_ai_message.id
      assert input.source_event_id == "cron:#{schedule.id}:#{DateTime.to_iso8601(first_slot)}"

      assert get_in(input.data, ["cron_fire_slot_at"]) ==
               DateTime.to_iso8601(first_slot)

      assert input.subject == "schedule:#{event.id}"
      assert get_in(input.data, ["wake_payload"]) == event.wake_payload
      assert event.wake_payload["trigger"] == "scheduled"
      assert event.wake_payload["cron_schedule_name"] == schedule.name
      assert event.wake_payload["payload"] == schedule.payload
      assert event.wake_payload["delivery"] == schedule.delivery

      assert input.type == "cron.fire"
      assert input.session_id == Schedule.cron_execution_session_id(schedule.id)
      assert input.session_id != schedule.owner_session_id
      assert input.conversation_id == public_conversation_id("mock:chat:schedule")
      assert input.provider_message_id == nil

      reloaded = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert reloaded.last_fire_at == first_slot
      assert reloaded.next_fire_at == DateTime.add(@base_time, 11, :minute)

      assert_persisted_equal(Schedule.list_cron_runs(schedule.id, 10), [event])
      assert cron_job(schedule.id).scheduled_at == reloaded.next_fire_at
    end

    test "cron schedules require explicit delivery and paused schedules do not advertise a live next fire" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:error, :cron_delivery_route_required} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   delivery: nil,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: :created, cron_schedule: paused}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   idempotency_key: "paused-cron-key",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert paused.status == :paused
      assert paused.next_fire_at == nil
      assert Schedule.list_cron_runs(paused.id, 10) == []
    end

    test "repeated cron creation preserves the complete durable row" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      attrs = cron_attrs(agent.uid, name: "idempotent-row", idempotency_key: "idempotent-row")

      assert {:ok, %{status: :created, cron_schedule: original}} =
               create_cron_schedule(attrs, now: @base_time)

      assert {:ok, %{status: :already_exists, cron_schedule: repeated}} =
               create_cron_schedule(attrs, now: DateTime.add(@base_time, 60))

      assert_persisted_equal(repeated, original)

      Ankole.DataCase.assert_persisted_equal(Repo.reload!(original), original)
    end

    test "cron delivery keeps targets and quiet success across independent updates" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      targets = [
        %{
          "binding_name" => "bot",
          "conversation_id" => public_conversation_id("mock:chat:schedule"),
          "provider_thread_id" => "thread-schedule"
        },
        %{
          "binding_name" => "secondary-bot",
          "conversation_id" => public_conversation_id("mock:chat:secondary")
        }
      ]

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "multi-target-delivery",
                   idempotency_key: "multi-target-delivery",
                   delivery: %{"targets" => targets},
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert schedule.delivery == %{"targets" => targets}

      assert {:ok, updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"quiet_success" => true}},
                 now: @base_time
               )

      assert updated.delivery == %{"targets" => targets, "quiet_success" => true}

      replacement_targets = [
        hd(targets),
        %{
          "binding_name" => "archive-bot",
          "conversation_id" =>
            public_conversation_id("mock:chat:archive", agent.uid, "archive-bot")
        }
      ]

      assert {:ok, route_updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"targets" => replacement_targets}},
                 now: @base_time
               )

      assert route_updated.delivery == %{
               "targets" => replacement_targets,
               "quiet_success" => true
             }

      assert {:ok, explicitly_noisy} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{
                   "delivery" => %{
                     "targets" => targets,
                     "quiet_success" => false
                   }
                 },
                 now: @base_time
               )

      assert explicitly_noisy.delivery == %{"targets" => targets, "quiet_success" => false}

      assert {:error, :duplicate_cron_delivery_target} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"targets" => [hd(targets), hd(targets)]}},
                 now: @base_time
               )

      assert {:error, :cron_primary_delivery_binding_mismatch} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"delivery" => %{"targets" => Enum.reverse(targets)}},
                 now: @base_time
               )
    end

    test "a scalar delivery route is rejected" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:error, :cron_delivery_route_required} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "invalid-target-list",
                   idempotency_key: "invalid-target-list",
                   delivery: %{"conversation_id" => public_conversation_id("mock:chat:legacy")}
                 ),
                 now: @base_time
               )
    end

    test "payload updates keep the slot and use the current facts when fired" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "snapshot-update",
                   idempotency_key: "snapshot-update",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert Schedule.list_cron_runs(schedule.id, 10) == []

      assert {:ok, updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{
                   "name" => "snapshot-update-renamed",
                   "payload" => %{"task" => "updated digest"}
                 },
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert updated.next_fire_at == first_slot
      assert updated.name == "snapshot-update-renamed"
      assert Schedule.list_cron_runs(schedule.id, 10) == []
      assert cron_job(schedule.id).scheduled_at == first_slot
      assert {:ok, %{scheduled_event: current}} = Schedule.fire_cron(schedule.id, now: first_slot)
      assert current.status == :fired
      assert current.wake_payload["cron_schedule_name"] == "snapshot-update-renamed"
      assert current.wake_payload["payload"] == %{"task" => "updated digest"}
    end

    test "pause and resume move one cron wakeup in the same deterministic slot" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "same-slot-resume",
                   idempotency_key: "same-slot-resume",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      original_job = cron_job(schedule.id)

      assert {:ok, paused} =
               Schedule.pause_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert paused.status == :paused
      assert paused.next_fire_at == nil
      assert Schedule.list_cron_runs(schedule.id, 10) == []
      assert {:ok, %{status: :noop}} = Schedule.fire_cron(schedule.id, now: first_slot)

      assert {:ok, resumed} =
               Schedule.resume_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert resumed.status == :active
      assert resumed.next_fire_at == first_slot

      assert cron_job(schedule.id).id == original_job.id
      assert cron_job(schedule.id).scheduled_at == first_slot
      assert Schedule.list_cron_runs(schedule.id, 10) == []

      assert {:ok, active_noop} =
               Schedule.resume_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert active_noop.next_fire_at == first_slot

      assert cron_job(schedule.id).scheduled_at == first_slot
      assert {:ok, %{status: :fired}} = Schedule.fire_cron(schedule.id, now: first_slot)
      assert {:ok, %{status: :noop}} = Schedule.fire_cron(schedule.id, now: first_slot)
    end

    test "a cron rule can move its job away from and return to the original slot" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      original_slot = DateTime.add(@base_time, 5, :minute)
      moved_slot = DateTime.add(@base_time, 10, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "slot-round-trip",
                   idempotency_key: "slot-round-trip",
                   schedule: every_schedule(original_slot)
                 ),
                 now: @base_time
               )

      assert {:ok, moved} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"schedule" => every_schedule(moved_slot)},
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert moved.next_fire_at == moved_slot
      assert cron_job(schedule.id).scheduled_at == moved_slot

      assert {:ok, restored} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"schedule" => every_schedule(original_slot)},
                 now: DateTime.add(@base_time, 2, :second)
               )

      assert restored.next_fire_at == original_slot

      assert cron_job(schedule.id).scheduled_at == original_slot
      assert Schedule.list_cron_runs(schedule.id, 10) == []
    end

    test "manual cron run replay uses the caller tool id and different calls stay distinct" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "manual-idempotency",
                   idempotency_key: "manual-idempotency"
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: :scheduled, scheduled_event: first}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "call-manual-1"
               )

      assert {:ok, %{status: :already_scheduled, scheduled_event: replayed}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second),
                 tool_call_id: "call-manual-1"
               )

      assert replayed.id == first.id

      assert {:ok, %{status: :scheduled, scheduled_event: second}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "call-manual-2"
               )

      assert second.id != first.id
      assert first.cron_fire_slot_at == second.cron_fire_slot_at

      assert {:ok, %{signal: first_input}} =
               Schedule.fire_due_event(first.id, now: @base_time)

      assert {:ok, %{signal: second_input}} =
               Schedule.fire_due_event(second.id, now: @base_time)

      assert first_input.source_event_id == "cron-manual:#{schedule.id}:call-manual-1"
      assert second_input.source_event_id == "cron-manual:#{schedule.id}:call-manual-2"
    end

    test "terminal recurring fire failure schedules the next slot" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "terminal-failure-continues",
                   idempotency_key: "terminal-failure-continues",
                   schedule: every_schedule(first_slot)
                 ),
                 now: @base_time
               )

      Repo.update!(Ecto.Changeset.change(schedule, authorization_kind: "review_required"))

      assert {:error, :work_authorization_review_required} =
               Schedule.fire_cron(schedule.id, now: first_slot, attempt: 3, max_attempts: 10)

      assert Schedule.list_cron_runs(schedule.id, 10) == []
      assert Repo.reload!(schedule).next_fire_at == first_slot

      assert {:error, :work_authorization_review_required} =
               Schedule.fire_cron(schedule.id, now: first_slot, attempt: 10, max_attempts: 10)

      assert {:ok, advanced} = Schedule.get_cron_schedule(schedule.id)
      assert advanced.next_fire_at == DateTime.add(first_slot, 1, :minute)

      assert [failed] = Schedule.list_cron_runs(schedule.id, 10)
      assert failed.status == :failed
      assert failed.cron_fire_slot_at == first_slot
      assert failed.last_fire_error["reason"] == ":work_authorization_review_required"
      assert cron_job(schedule.id).scheduled_at == advanced.next_fire_at
    end

    test "a count bound completes the schedule after its due slots, ignoring manual runs" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "count-bounded",
                   idempotency_key: "count-bounded",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"count" => 2}
                   }
                 ),
                 now: @base_time
               )

      assert schedule.schedule["occurrences"] == %{"count" => 2}

      # A manual run is outside the recurrence and must not spend the budget.
      assert {:ok, %{status: :scheduled, scheduled_event: manual}} =
               Schedule.run_cron_schedule(schedule.id, tool_call_id: "manual-1", now: @base_time)

      assert {:ok, %{status: :fired}} = Schedule.fire_due_event(manual.id, now: @base_time)

      assert {:ok, %{status: :fired}} = Schedule.fire_cron(schedule.id, now: first_slot)

      assert {:ok, after_first} = Schedule.get_cron_schedule(schedule.id)
      assert after_first.status == :active
      second_slot = DateTime.add(first_slot, 1, :minute)
      assert after_first.next_fire_at == second_slot

      assert {:ok, %{status: :fired}} = Schedule.fire_cron(schedule.id, now: second_slot)

      assert {:ok, completed} = Schedule.get_cron_schedule(schedule.id)
      assert completed.status == :completed
      assert completed.next_fire_at == nil

      assert [] ==
               for(
                 run <- Schedule.list_cron_runs(schedule.id, 10),
                 run.status == :scheduled,
                 do: run
               )

      # Terminal state: only removal remains available.
      assert {:error, :cron_schedule_completed} =
               Schedule.pause_cron_schedule(schedule.id, now: second_slot)

      assert {:error, :cron_schedule_completed} =
               Schedule.resume_cron_schedule(schedule.id, now: second_slot)

      assert {:error, :cron_schedule_completed} =
               Schedule.run_cron_schedule(schedule.id, tool_call_id: "manual-2", now: second_slot)

      assert {:error, :cron_schedule_completed} =
               Schedule.update_cron_schedule(schedule.id, %{"payload" => %{"task" => "late"}},
                 now: second_slot
               )

      assert {:ok, removed} = Schedule.remove_cron_schedule(schedule.id, now: second_slot)
      assert removed.status == :deleted
    end

    test "a count bound treats a terminally failed slot as consumed" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "count-bounded-failure",
                   idempotency_key: "count-bounded-failure",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"count" => 1}
                   }
                 ),
                 now: @base_time
               )

      Repo.update!(Ecto.Changeset.change(schedule, authorization_kind: "review_required"))

      assert {:error, :work_authorization_review_required} =
               Schedule.fire_cron(schedule.id, now: first_slot, attempt: 10, max_attempts: 10)

      assert [failed] = Schedule.list_cron_runs(schedule.id, 10)
      assert failed.status == :failed

      assert {:ok, completed} = Schedule.get_cron_schedule(schedule.id)
      assert completed.status == :completed
      assert completed.next_fire_at == nil
    end

    test "an until bound stops after the cutoff and rejects a cutoff before the first occurrence" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      cutoff = DateTime.add(@base_time, 90, :second)

      assert {:error, :schedule_occurrences_exhausted} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "until-before-first",
                   idempotency_key: "until-before-first",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"until" => DateTime.to_iso8601(@base_time)}
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "until-bounded",
                   idempotency_key: "until-bounded",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"until" => DateTime.to_iso8601(cutoff)}
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: :fired}} = Schedule.fire_cron(schedule.id, now: first_slot)

      assert {:ok, completed} = Schedule.get_cron_schedule(schedule.id)
      assert completed.status == :completed
      assert completed.next_fire_at == nil
    end

    test "resume completes a paused schedule whose bound ran out while paused" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      cutoff = DateTime.add(@base_time, 90, :second)
      after_cutoff = DateTime.add(@base_time, 10, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "resume-past-until",
                   idempotency_key: "resume-past-until",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"until" => DateTime.to_iso8601(cutoff)}
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, paused} = Schedule.pause_cron_schedule(schedule.id, now: @base_time)
      assert paused.status == :paused

      assert {:ok, resumed} = Schedule.resume_cron_schedule(schedule.id, now: after_cutoff)
      assert resumed.status == :completed
      assert resumed.next_fire_at == nil
    end

    test "an update whose new bound is already spent is rejected" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "update-spent-bound",
                   idempotency_key: "update-spent-bound",
                   schedule: every_schedule(first_slot)
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: :fired}} = Schedule.fire_cron(schedule.id, now: first_slot)

      assert {:error, :schedule_occurrences_exhausted} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{
                   "schedule" => %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "anchor_at" => DateTime.to_iso8601(first_slot),
                     "occurrences" => %{"count" => 1}
                   }
                 },
                 now: DateTime.add(first_slot, 5, :second)
               )

      assert {:ok, unchanged} = Schedule.get_cron_schedule(schedule.id)
      assert unchanged.status == :active
      assert unchanged.schedule["occurrences"] == nil
    end

    @tag ownership_timeout: 10_000
    test "a concurrent recurring fire and payload update serialize without a deadlock" do
      parent = self()
      first_slot = DateTime.add(@base_time, 1, :minute)
      unique = Ecto.UUID.generate()

      {tenant_id, agent_uid, schedule} =
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          tenant =
            create_committed_tenant(%{
              slug: "schedule-" <> Ecto.UUID.generate(),
              display_name: "Schedule concurrency test"
            })

          Repo.with_tenant(tenant.id, fn ->
            %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

            assert {:ok, %{cron_schedule: schedule}} =
                     create_cron_schedule(
                       cron_attrs(agent.uid,
                         name: "concurrent-#{unique}",
                         idempotency_key: "concurrent-#{unique}",
                         schedule: every_schedule(first_slot)
                       ),
                       now: @base_time
                     )

            {tenant.id, agent.uid, schedule}
          end)
        end)

      Repo.put_tenant_id(tenant_id)

      on_exit(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.put_tenant_id(tenant_id)

          Oban.Job
          |> where([job], job.worker == "Ankole.Schedule.Jobs.FireCron")
          |> where([job], fragment("?->>'cron_schedule_id' = ?", job.args, ^schedule.id))
          |> Repo.delete_all()

          Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent_uid)
          Repo.delete_all(Ankole.Conversations.Conversation)
          Repo.get!(Ankole.Tenants.Tenant, tenant_id) |> cleanup_tenant!()
        end)
      end)

      blocker =
        Task.async(
          Repo.bind_tenant(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              Repo.transact(fn repo ->
                rule =
                  CronSchedule
                  |> where([scheduled_event], scheduled_event.id == ^schedule.id)
                  |> lock("FOR UPDATE")
                  |> repo.one!(lock_identity: {"cron_schedules", schedule.id})

                send(parent, {:recurring_event_locked, self()})

                receive do
                  :release_recurring_event -> {:ok, rule.id}
                end
              end)
            end)
          end)
        )

      assert_receive {:recurring_event_locked, blocker_pid}, 5_000

      fire =
        Task.async(
          Repo.bind_tenant(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              Schedule.fire_cron(schedule.id, now: first_slot)
            end)
          end)
        )

      Process.sleep(50)

      update =
        Task.async(
          Repo.bind_tenant(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              Schedule.update_cron_schedule(
                schedule.id,
                %{"payload" => %{"version" => 2, "task" => "digest"}},
                now: first_slot
              )
            end)
          end)
        )

      Process.sleep(50)
      send(blocker_pid, :release_recurring_event)

      assert {:ok, id} = Task.await(blocker, 5_000)
      assert id == schedule.id
      assert {:ok, %{status: :fired}} = Task.await(fire, 5_000)
      assert {:ok, %CronSchedule{}} = Task.await(update, 5_000)

      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        assert {:ok, current} = Schedule.get_cron_schedule(schedule.id)
        assert current.status == :active

        assert cron_job(schedule.id).scheduled_at == current.next_fire_at
        assert current.payload == %{"version" => 2, "task" => "digest"}
        assert [%ScheduledEvent{status: :fired}] = Schedule.list_cron_runs(schedule.id, 10)

        source_event_id = "cron:#{schedule.id}:#{DateTime.to_iso8601(first_slot)}"

        assert Signal
               |> where([signal], signal.source_event_id == ^source_event_id)
               |> Repo.aggregate(:count) == 1
      end)
    end

    test "deleted cron names can be reused without poisoning list or name lookup" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: removed}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "reusable-name",
                   idempotency_key: "reusable-name-old"
                 ),
                 now: @base_time
               )

      assert {:ok, %{status: :deleted}} = Schedule.remove_cron_schedule(removed.id)

      assert {:ok, %{cron_schedule: current}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "reusable-name",
                   idempotency_key: "reusable-name-current"
                 ),
                 now: @base_time
               )

      assert {:ok, fetched} =
               Schedule.get_cron_schedule_by_name(
                 agent.uid,
                 current.owner_session_id,
                 "reusable-name"
               )

      assert fetched.id == current.id

      assert Enum.map(
               Schedule.list_cron_schedules(agent.uid, current.owner_session_id),
               & &1.id
             ) == [
               current.id
             ]

      assert {:ok, %{status: :deleted}} = Schedule.get_cron_schedule(removed.id)
    end

    test "cron updates reject empty and unknown changes" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "validated-update",
                   idempotency_key: "validated-update"
                 ),
                 now: @base_time
               )

      assert {:error, :cron_schedule_update_required} =
               Schedule.update_cron_schedule(schedule.id, %{})

      assert {:error, {:unknown_cron_schedule_update_fields, ["failure_policy"]}} =
               Schedule.update_cron_schedule(schedule.id, %{"failure_policy" => %{}})
    end

    test "direct-Agent cron requires a self-contained task and a real owner conversation" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:error, :cron_task_required} =
               create_cron_schedule(
                 cron_attrs(agent.uid, payload: %{}),
                 now: @base_time
               )

      assert {:error, :cron_task_required} =
               create_cron_schedule(
                 cron_attrs(agent.uid, payload: %{"task" => "   "}),
                 now: @base_time
               )

      assert {:error, :cron_owner_session_reserved} =
               create_cron_schedule(
                 cron_attrs(agent.uid, owner_session_id: "cron:#{Ecto.UUID.generate()}"),
                 now: @base_time
               )

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid, status: "paused", name: "task-guard"),
                 now: @base_time
               )

      assert {:error, :cron_task_required} =
               Schedule.update_cron_schedule(schedule.id, %{"payload" => %{"notes" => "no task"}})

      assert {:ok, updated} =
               Schedule.update_cron_schedule(schedule.id, %{"payload" => %{"task" => "new task"}})

      assert updated.payload == %{"task" => "new task"}

      assert {:ok, %{scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "legacy-task-guard"
               )

      CronSchedule
      |> where([cron_schedule], cron_schedule.id == ^schedule.id)
      |> Repo.update_all(set: [payload: %{}])

      assert {:error, :cron_task_required} =
               Schedule.resume_cron_schedule(schedule.id, now: @base_time)

      assert {:error, :cron_task_required} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "legacy-task-guard-retry"
               )

      assert {:ok, %{status: :cancelled, scheduled_event: cancelled}} =
               Schedule.fire_due_event(manual_event.id, now: @base_time)

      assert cancelled.last_fire_error == %{"reason" => ":cron_task_required"}

      assert {:ok, repaired} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "payload" => %{"task" => "restored task"}
               })

      assert repaired.payload == %{"task" => "restored task"}

      assert {:ok, %{status: :active}} =
               Schedule.resume_cron_schedule(schedule.id, now: @base_time)
    end

    test "payload and delivery changes end the execution conversation and terminal states end it too" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid, status: "paused", name: "conversation-lifecycle"),
                 now: @base_time
               )

      execution_session_id = Schedule.cron_execution_session_id(schedule.id)

      ensure_execution_conversation = fn ->
        {:ok, conversation} =
          Ankole.AIGatewayCase.ensure_conversation(agent.uid, execution_session_id)

        conversation
      end

      active_execution_conversation = fn ->
        Ankole.Sessions.ModelHistory.active_conversation(agent.uid, execution_session_id)
      end

      first = ensure_execution_conversation.()

      # A time-only change keeps the execution conversation and its history.
      assert {:ok, _updated} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "schedule" => every_schedule(DateTime.add(@base_time, 2, :minute))
               })

      assert active_execution_conversation.().id == first.id

      # A task change makes the old history a wrong prefix, so it ends.
      assert {:ok, _updated} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "payload" => %{"task" => "changed task"}
               })

      assert active_execution_conversation.() == nil

      second = ensure_execution_conversation.()

      assert {:ok, _updated} =
               Schedule.update_cron_schedule(schedule.id, %{
                 "delivery" => %{
                   "targets" => [
                     %{
                       "binding_name" => "bot",
                       "conversation_id" =>
                         public_conversation_id("mock:chat:elsewhere", agent.uid, "bot"),
                       "provider_thread_id" => "thread-elsewhere"
                     }
                   ]
                 }
               })

      assert active_execution_conversation.() == nil

      third = ensure_execution_conversation.()
      assert {:ok, %{status: :deleted}} = Schedule.remove_cron_schedule(schedule.id)
      assert active_execution_conversation.() == nil
      assert Enum.uniq([first.id, second.id, third.id]) |> length() == 3
    end

    test "a timezone-only cron update moves its wakeup and uses the new zone at fire" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "timezone-update",
                   idempotency_key: "timezone-update",
                   schedule: %{
                     "kind" => "cron",
                     "expression" => "0 9 * * *",
                     "timezone" => "Etc/UTC"
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, updated} =
               Schedule.update_cron_schedule(
                 schedule.id,
                 %{"timezone" => "Asia/Shanghai"},
                 now: @base_time
               )

      assert updated.timezone == "Asia/Shanghai"
      assert updated.schedule["timezone"] == "Asia/Shanghai"

      assert cron_job(schedule.id).scheduled_at == updated.next_fire_at

      assert {:ok, %{scheduled_event: event}} =
               Schedule.fire_cron(schedule.id, now: updated.next_fire_at)

      assert event.timezone == "Asia/Shanghai"
      assert event.wake_payload["timezone"] == "Asia/Shanghai"
      assert event.cron_fire_slot_at == updated.next_fire_at
    end

    test "manual cron runs fire while paused without advancing recurrence" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      now = DateTime.add(@base_time, 1, :second)

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "manual-paused",
                   idempotency_key: "manual-paused",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(DateTime.add(now, 1, :minute))
                   }
                 ),
                 now: now
               )

      assert {:ok, %{status: :scheduled, scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: now,
                 tool_call_id: "manual-paused-call"
               )

      assert manual_event.wake_payload["trigger"] == "manual"

      assert {:ok, %{status: :fired, signal: signal}} =
               Schedule.fire_due_event(manual_event.id, now: now)

      assert signal.type == "cron.fire"

      assert {:ok, unchanged} = Schedule.get_cron_schedule(schedule.id)
      assert unchanged.status == :paused
      assert unchanged.next_fire_at == nil
      assert unchanged.last_fire_at == nil
    end

    test "pausing preserves a pending manual run while cancelling recurrence" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      first_slot = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "manual-before-pause",
                   idempotency_key: "manual-before-pause",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "manual-before-pause-call"
               )

      assert {:ok, paused} =
               Schedule.pause_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert paused.status == :paused

      runs = Schedule.list_cron_runs(schedule.id, 10)
      assert Repo.get!(ScheduledEvent, manual_event.id).status == :scheduled
      assert_persisted_equal(runs, [Repo.reload!(manual_event)])
      assert {:ok, %{status: :noop}} = Schedule.fire_cron(schedule.id, now: first_slot)

      assert {:ok, %{status: :fired}} =
               Schedule.fire_due_event(manual_event.id,
                 now: DateTime.add(@base_time, 1, :second)
               )
    end

    test "deleted cron schedules reject new manual runs and cancel pending ones" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   status: "paused",
                   name: "manual-before-delete",
                   idempotency_key: "manual-before-delete"
                 ),
                 now: @base_time
               )

      assert {:ok, %{scheduled_event: manual_event}} =
               Schedule.run_cron_schedule(schedule.id,
                 now: @base_time,
                 tool_call_id: "manual-before-delete-call"
               )

      assert {:ok, deleted} =
               Schedule.remove_cron_schedule(schedule.id,
                 now: DateTime.add(@base_time, 1, :second)
               )

      assert deleted.status == :deleted
      assert Repo.get!(ScheduledEvent, manual_event.id).status == :cancelled
      assert {:error, :cron_schedule_deleted} = Schedule.run_cron_schedule(schedule.id)
    end

    test "cron created_by is trusted context, not caller attrs" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{status: :created, cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   name: "created-by-attrs-ignored",
                   idempotency_key: "created-by-attrs-ignored",
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 86_400_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(DateTime.add(@base_time, 1, :day))
                   },
                   created_by: %{
                     "kind" => "spoofed",
                     "origin_ai_message_id" => Ecto.UUID.generate()
                   }
                 ),
                 now: @base_time
               )

      assert schedule.created_by == %{
               "kind" => "operator_api",
               "principal_uid" => to_string(Ankole.ActorRef.from_principal(agent))
             }

      assert {:ok, %{scheduled_event: event}} =
               Schedule.fire_cron(schedule.id, now: schedule.next_fire_at)

      assert event.origin_ai_message_id == nil
    end

    test "resource transitions cannot revive a terminal event" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      attrs = checkback_attrs(agent.uid, [])

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert {:ok, cancelled} = Schedule.cancel_checkback(event.id, now: @base_time)

      for action <- [:fire, :reschedule, :fail, :record_error] do
        assert {:ok, %Ash.Error.Invalid{errors: errors}} =
                 Repo.transact(fn _repo ->
                   {:error, error} = Ankole.Ash.update(cancelled, action, %{})
                   {:ok, error}
                 end)

        assert Enum.any?(errors, &match?(%AshStateMachine.Errors.NoMatchingTransition{}, &1))
      end

      assert {:ok, %{status: :already_scheduled, scheduled_event: repeated}} =
               Schedule.create_check_back_later(attrs, now: @base_time)

      assert_persisted_equal(repeated, cancelled)

      Ankole.DataCase.assert_persisted_equal(Repo.get!(ScheduledEvent, event.id), cancelled)

      assert Repo.aggregate(from(signal in Signal, where: signal.type != "test.work"), :count) ==
               0
    end

    test "rescheduling cannot change ownership, authorization, or creation facts" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(checkback_attrs(agent.uid, []), now: @base_time)

      for attrs <- [
            %{agent_uid: Ecto.UUID.generate()},
            %{session_id: "another-session"},
            %{authorization_kind: "service"},
            %{human_uid: Ecto.UUID.generate()},
            %{human_access_version: 10},
            %{kind: "cron_fire"},
            %{cron_schedule_id: Ecto.UUID.generate()},
            %{source_signal_id: Ecto.UUID.generate()},
            %{idempotency_key: "replacement"},
            %{requested_at: DateTime.add(@base_time, 60)},
            %{source_provenance: %{"replacement" => true}},
            %{due_att: @base_time}
          ] do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 Repo.transact(fn _ -> Ankole.Ash.update(event, :reschedule, attrs) end)

        assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{}, &1))
        assert_persisted_equal(Repo.get!(ScheduledEvent, event.id), event)
      end

      due_at = DateTime.add(event.due_at, 60)

      assert {:ok, updated} =
               Repo.transact(fn _ ->
                 Ankole.Ash.update(event, :reschedule, %{due_at: due_at})
               end)

      assert updated.due_at == due_at
      assert updated.status == :scheduled
    end

    test "resource transitions require the caller transaction" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(checkback_attrs(agent.uid, []), now: @base_time)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ankole.Ash.update(event, :cancel, %{cancelled_at: @base_time})

      assert Enum.any?(errors, &(&1.message == "transaction required"))
      assert Repo.get!(ScheduledEvent, event.id).status == :scheduled
    end

    test "scheduled event correlation ids must reference durable rows" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:error, :work_authorization_review_required} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   idempotency_key: "missing-source-actor-event",
                   source_signal_id: Ecto.UUID.generate(),
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   idempotency_key: "missing-origin-ai-message",
                   origin_ai_message_id: Ecto.UUID.generate(),
                   schedule: %{"at" => DateTime.to_iso8601(due_at), "timezone" => "Etc/UTC"}
                 ),
                 now: @base_time
               )

      assert Enum.any?(errors, fn error ->
               error.field == :origin_ai_message_id and
                 error.private_vars[:constraint] == "scheduled_events_origin_ai_message_id_fkey" and
                 error.private_vars[:constraint_type] == :foreign_key
             end)

      assert {:error, %Ash.Error.Invalid{} = changeset} =
               Repo.transact(fn ->
                 with {:ok, event} <-
                        Ankole.Ash.create(ScheduledEvent, :create_event, %{
                          kind: "check_back_later",
                          agent_uid: agent.uid,
                          session_id: "mock:chat:schedule",
                          binding_name: "bot",
                          due_at: due_at,
                          timezone: "Etc/UTC",
                          requested_at: @base_time,
                          idempotency_key: "missing-fired-actor-event",
                          source_provenance: %{},
                          wake_payload: %{},
                          last_fire_error: %{}
                        }) do
                   Ankole.Ash.update(event, :fire, %{
                     signal_id: Ecto.UUID.generate(),
                     fired_at: due_at
                   })
                 end
               end)

      assert %{signal_id: [_ | _]} = errors_on(changeset)
    end

    test "cancelled checkback does not fire after source entry tombstone" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)

      assert {:ok, %{signal: source_event}} =
               emit_entry(agent.uid, "bot", group_entry(%{explicit: true}), now: @base_time)

      assert {:ok, _consumed} =
               complete_signal(
                 agent.uid,
                 "bot",
                 source_event.source_event_id,
                 actor_commit_opts(completed_at: DateTime.add(@base_time, 1, :second))
               )

      due_at = DateTime.add(@base_time, 5, :minute)

      assert {:ok, %{scheduled_event: event}} =
               Schedule.create_check_back_later(
                 checkback_attrs(agent.uid,
                   session_id: source_event.session_id,
                   reply_route: %{
                     "conversation_id" => source_event.conversation_id,
                     "provider_thread_id" => source_event.provider_thread_id,
                     "provider_message_id" => source_event.provider_message_id
                   },
                   source_signal_id: source_event.id,
                   schedule: %{
                     "at" => DateTime.to_iso8601(due_at),
                     "timezone" => "Etc/UTC"
                   }
                 ),
                 now: @base_time
               )

      assert {:ok, %{lifecycle_events: [lifecycle_event]}} =
               Repo.transact(fn _repo ->
                 Observe.emit_entry_removed(
                   agent.uid,
                   "bot",
                   lifecycle_entry(%{source_event_id: "delete-source"}),
                   now: DateTime.add(@base_time, 2, :second)
                 )
               end)

      assert {:ok, %{status: :entry_lifecycle_ignored, cancelled_checkbacks: 1}} =
               Ankole.Sessions.MessageLifecycle.process(
                 lifecycle_event,
                 now: DateTime.add(@base_time, 3, :second)
               )

      assert %Signal{completed_at: %DateTime{}} = Repo.get(Signal, lifecycle_event.id)
      assert Repo.get!(ScheduledEvent, event.id).status == :cancelled

      assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: event.due_at)
    end
  end

  describe "conversation schedule tools and turns" do
    test "a checkback uses the current reply route and survives Driver replacement" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "mock", :ignore, "mock-provider")

      {:ok, %{signal: source}} =
        emit_entry(agent.uid, "mock", group_entry(%{explicit: true}), now: @base_time)

      run = admit_input(source, @base_time)

      args = %{
        "action" => "create",
        "reason" => "Follow up",
        "check" => "Read the status",
        "schedule" => %{"after" => %{"value" => 1, "unit" => "minute"}},
        "quiet_success" => true
      }

      {run, result} = execute_tool(run, "check_back_later", args)
      refute result.is_error
      [event] = Repo.all(from(e in ScheduledEvent, where: e.kind == "check_back_later"))
      assert event.session_id == source.session_id
      assert event.binding_name == source.reply_binding_name
      assert event.conversation_id == source.conversation_id
      assert event.source_signal_id == source.id
      replacement = admit_input(Repo.reload!(source), DateTime.utc_now(:microsecond))
      assert replacement.epoch > run.epoch
      {_, repeated} = execute_tool(replacement, "check_back_later", args)
      assert repeated.details["status"] == "already_scheduled"
      assert repeated.details["due_at"] == result.details["due_at"]

      assert Repo.aggregate(
               from(e in ScheduledEvent, where: e.kind == "check_back_later"),
               :count
             ) == 1

      assert Repo.get!(Ankole.AgentWorkers.AgentWorker, agent.uid).state ==
               :absent
    end

    test "mock IM dashboard cron fires through Oban and posts service lines" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "mock-provider", :ignore, "mock-provider")

      consumer =
        MockInbound.chat_consumer(mock_adapter_context(agent.uid, "mock-provider"), %{},
          now: @base_time
        )

      {:ok, [received]} =
        Repo.transact(fn _repo ->
          MockInbound.handle_message_receive(
            "message.receive",
            %{
              source_event_id: "mock-dashboard-cron-request",
              conversation_id: "mock:chat:dashboard",
              provider_message_id: "mock-dashboard-request-message",
              provider_thread_id: "mock-dashboard-thread",
              text: "Every morning at 7 check https://status.internal and report each service.",
              explicit: true,
              now: @base_time,
              provider_time: @base_time
            },
            [consumer]
          )
        end)

      {:ok, received} =
        Repo.transact(fn _repo -> {:ok, maybe_finalize_test_inbound_batch(received)} end)

      source = received.signal
      run = admit_input(source, @base_time)

      {run, result} =
        execute_tool(run, "cron", %{
          "action" => "add",
          "name" => "dashboard-morning-check",
          "schedule" => %{
            "kind" => "cron",
            "expression" => "0 7 * * *",
            "timezone" => "Asia/Shanghai"
          },
          "payload" => %{
            "task" => "dashboard_status_check",
            "dashboard_url" => "https://status.internal",
            "services" => ["api", "billing", "search"]
          }
        })

      refute result.is_error

      {:ok, schedule} =
        Schedule.get_cron_schedule_by_name(
          agent.uid,
          source.session_id,
          "dashboard-morning-check"
        )

      ack = complete_turn_via_aigateway!(run, "Scheduled for 07:00 Asia/Shanghai.")
      dispatch_final_reply_intent!(ack.id)
      assert wait_for_final_mirror(ack.id).message.conversation_id == source.conversation_id
      due = DateTime.add(DateTime.utc_now(:microsecond), -1)

      assert {:ok, _schedule} =
               Repo.transact(fn _ ->
                 Ankole.Ash.update(schedule, :schedule_fire, %{next_fire_at: due})
               end)

      assert :ok =
               Repo.transact(fn _repo ->
                 {:ok,
                  perform_job(Ankole.Schedule.Jobs.FireCron, %{
                    "cron_schedule_id" => schedule.id
                  })}
               end)
               |> elem(1)

      [event] = Schedule.list_cron_runs(schedule.id, 10)
      input = Repo.get!(Signal, event.signal_id)
      assert input.type == "cron.fire"
      assert input.conversation_id == source.conversation_id

      assert get_in(input.data, ["wake_payload", "payload", "dashboard_url"]) ==
               "https://status.internal"

      run = admit_input(input, DateTime.utc_now(:microsecond))
      assert run.kind == :scheduled
      assert run.spec.request_context["silent_success_allowed"] == false
      report = "api: green\nbilling: green\nsearch: degraded since 06:42 Asia/Shanghai"

      final =
        complete_turn_via_aigateway!(run, report)

      dispatch_final_reply_intent!(final.id)
      mirror = wait_for_final_mirror(final.id)
      assert mirror.message.text == report
      assert mirror.message.conversation_id == source.conversation_id
      assert mirror.external_ref.metadata["signal_id"] == input.id
    end

    test "a checkback can finish silently only with explicit quiet success" do
      %{principal: agent} = agent_fixture()
      due = DateTime.add(@base_time, 60)

      for quiet <- [false, true] do
        {:ok, %{scheduled_event: event}} =
          Schedule.create_check_back_later(
            checkback_attrs(agent.uid,
              quiet_success: quiet,
              idempotency_key: "quiet-#{quiet}",
              schedule: %{"at" => DateTime.to_iso8601(due), "timezone" => "Etc/UTC"}
            ),
            now: @base_time
          )

        {:ok, %{signal: input}} =
          Repo.transact(fn _repo -> Schedule.fire_due_event(event.id, now: due) end)

        run = admit_input(input, due)
        {run, result} = execute_finish(run, "silent_success", nil)

        if quiet do
          refute result.is_error

          turn = %Ankole.Sessions.Turn{
            key: %{agent_uid: run.agent_uid, session_id: run.session_id},
            stage: :boundary,
            run: run
          }

          assert {%{run: %{outcome: :silent}}, [{:finalize, :silent, nil}]} =
                   Ankole.Sessions.Turn.step(turn, {:completed, :boundary, {:ok, run}})

          assert {:ok, _} = Run.finalize(run, :silent)
          assert Repo.reload!(input).completed_at
        else
          assert result.is_error
          assert result.output =~ "schedule_silent_success_not_allowed"

          refute Repo.reload!(input).completed_at
          assert {:ok, _} = Run.finalize(run, :stopped)
        end
      end

      assert Repo.aggregate(Intent, :count) == 0
    end

    test "cron replies post to configured delivery without a Worker" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, "mock-provider")
      seed_mock_channel(agent.uid, "bot")
      {_, input, run, _} = fire_cron(agent.uid)

      final =
        complete_turn_via_aigateway!(
          run,
          "Daily digest is ready."
        )

      dispatch_final_reply_intent!(final.id)
      mirror = wait_for_final_mirror(final.id)
      assert mirror.message.conversation_id == public_conversation_id("mock:chat:schedule")
      assert mirror.message.text == "Daily digest is ready."
      assert mirror.external_ref.metadata["signal_id"] == input.id

      assert Repo.get!(Ankole.AgentWorkers.AgentWorker, agent.uid).state ==
               :absent
    end

    test "an owner turn and its cron use different conversations; fires keep queue order" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, "mock-provider")
      seed_mock_channel(agent.uid, "bot")

      {:ok, %{signal: owner}} =
        emit_entry(agent.uid, "bot", group_entry(%{explicit: true}), now: @base_time)

      owner_run = admit_input(owner, @base_time)
      {schedule, input, run, due} = fire_cron(agent.uid, owner_session_id: owner.session_id)
      refute run.conversation.id == owner_run.conversation.id
      refute Repo.reload!(owner).completed_at

      {:ok, %{scheduled_event: manual}} =
        Schedule.run_cron_schedule(schedule.id, idempotency_key: "manual-while-running", now: due)

      {:ok, %{signal: next}} =
        Repo.transact(fn _repo -> Schedule.fire_due_event(manual.id, now: due) end)

      assert next.session_id == input.session_id

      assert Ankole.Sessions.Queue.next_ready_event(agent.uid, input.session_id, due).id ==
               input.id

      complete_turn_via_aigateway!(run, "First fire done.")

      assert Ankole.Sessions.Queue.next_ready_event(agent.uid, input.session_id, due).id ==
               next.id
    end

    test "a cron-origin turn sees only its schedule and can pause it to stop" do
      %{principal: agent} = agent_fixture()
      {schedule, _, run, _} = fire_cron(agent.uid)
      [cron] = Enum.filter(run.tools, &(&1.name == "cron"))
      assert cron.schema["parameters"]["properties"]["action"]["enum"] == ~w(list get runs pause)

      for action <- ~w(add update resume remove run) do
        call = %{
          "type" => "function_call",
          "name" => "cron",
          "call_id" => Ecto.UUID.generate(),
          "arguments" => Ankole.JSON.encode!(%{"action" => action, "name" => "daily-digest"})
        }

        assert {:error, %{failure_kind: "invalid_arguments"}} = Tools.prepare(run, call)
      end

      {run, listed} = execute_tool(run, "cron", %{"action" => "list"})
      assert [%{"name" => "daily-digest"}] = listed.details["schedules"]
      {run, runs} = execute_tool(run, "cron", %{"action" => "runs"})
      assert [projected | _] = runs.details["runs"]
      assert Map.has_key?(projected, "trigger")

      for key <-
            ~w(cron_schedule_id wake_payload source_provenance last_fire_error),
          do: refute(Map.has_key?(projected, key))

      {run, paused} = execute_tool(run, "cron", %{"action" => "pause"})
      refute paused.is_error
      assert Repo.reload!(schedule).status == :paused

      # Pausing keeps the execution conversation, so the turn still replies.
      complete_turn_via_aigateway!(run, "Done; paused.")
    end

    test "cron quiet success consumes the fire without an intent" do
      %{principal: agent} = agent_fixture()

      {_, input, run, _} =
        fire_cron(agent.uid,
          delivery: %{
            "targets" => [
              %{
                "binding_name" => "bot",
                "conversation_id" => public_conversation_id("mock:chat:schedule")
              }
            ],
            "quiet_success" => true
          }
        )

      assert run.spec.request_context["silent_success_allowed"]
      {run, result} = execute_finish(run, "silent_success", nil)
      refute result.is_error
      assert {:ok, _} = Run.finalize(run, :silent)
      assert Repo.reload!(input).completed_at
      assert Repo.aggregate(Intent, :count) == 0
    end

    test "session reset preserves an overdue cron fire until it materializes" do
      %{principal: agent} = agent_fixture()
      first_slot = DateTime.add(@base_time, 1, :minute)
      reset_at = DateTime.add(@base_time, 2, :minute)

      assert {:ok, %{cron_schedule: schedule}} =
               create_cron_schedule(
                 cron_attrs(agent.uid,
                   schedule: %{
                     "kind" => "every",
                     "every_ms" => 60_000,
                     "timezone" => "Etc/UTC",
                     "anchor_at" => DateTime.to_iso8601(first_slot)
                   }
                 ),
                 now: @base_time
               )

      execution_session_id = Schedule.cron_execution_session_id(schedule.id)

      assert {:ok, _conversation} =
               Ankole.AIGatewayCase.ensure_conversation(agent.uid, execution_session_id)

      assert Schedule.list_cron_runs(schedule.id, 10) == []
      assert schedule.next_fire_at == first_slot

      assert {:ok, reset_event} =
               append_runtime_signal(agent.uid, execution_session_id, "session.reset_due",
                 now: reset_at,
                 boundary_at: reset_at
               )

      assert {:ok,
              %{
                status: :session_reset,
                reset_event: processed_reset
              }} =
               Ankole.Sessions.SessionReset.process_due(
                 %{agent_uid: agent.uid, session_id: execution_session_id},
                 reset_event,
                 now: reset_at
               )

      assert_persisted_equal(processed_reset, reset_event)
      assert Schedule.list_cron_runs(schedule.id, 10) == []

      before_fire = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert before_fire.last_fire_at == nil
      assert before_fire.next_fire_at == first_slot

      assert {:ok, %{status: :fired, signal: cron_input}} =
               Schedule.fire_cron(schedule.id, now: reset_at)

      assert cron_input.type == "cron.fire"

      assert cron_input.source_event_id ==
               "cron:#{schedule.id}:#{DateTime.to_iso8601(first_slot)}"

      assert get_in(cron_input.data, ["cron_fire_slot_at"]) ==
               DateTime.to_iso8601(first_slot)

      assert {:ok, %{status: :noop}} = Schedule.fire_cron(schedule.id, now: reset_at)

      reloaded = Schedule.get_cron_schedule(schedule.id) |> elem(1)
      assert reloaded.last_fire_at == first_slot
      assert reloaded.next_fire_at == DateTime.add(@base_time, 3, :minute)

      runs = Schedule.list_cron_runs(schedule.id, 10)

      assert Enum.map(runs, &{&1.status, &1.due_at}) == [
               {:fired, first_slot}
             ]
    end
  end

  defp agent_fixture(attrs \\ %{}) do
    %{principal: agent} = fixture = Ankole.PrincipalsFixtures.agent_fixture(attrs)
    provider_id = "schedule-test-" <> Ecto.UUID.generate()

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: "https://openrouter.ai/api/v1",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    :ok = Ankole.SessionsCase.cache_actor_runtime_models(provider_id)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: provider_id,
               model: "google/gemini-3.5-flash"
             })

    fixture
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        enabled_ids: MapSet.new([spec.id])
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp seed_mock_channel(agent_uid, binding_name) do
    consumer =
      MockInbound.chat_consumer(
        mock_adapter_context(agent_uid, binding_name),
        %{},
        now: @base_time
      )

    assert {:ok, [_result]} =
             MockInbound.handle_message_receive(
               "message.receive",
               %{
                 source_event_id: "mock-channel-seed-#{binding_name}",
                 conversation_id: "mock:chat:schedule",
                 provider_message_id: "mock-channel-seed-message-#{binding_name}",
                 provider_thread_id: "thread-schedule",
                 text: "channel seed",
                 explicit: false,
                 now: @base_time,
                 provider_time: @base_time
               },
               [consumer]
             )
  end

  defp admit_input(event, now) do
    {:ok, run} =
      Admission.admit(%{agent_uid: event.agent_uid, session_id: event.session_id}, event,
        now: now
      )

    {:ok, context} = Context.resolve(run.agent_uid, run.session_id)
    run = %{run | context: context}
    {tools, _} = ToolCatalog.for_run(run)
    %{run | context: context, tools: tools}
  end

  defp execute_tool(run, name, args) do
    call = %{
      "type" => "function_call",
      "name" => name,
      "call_id" => Ecto.UUID.generate(),
      "arguments" => Ankole.JSON.encode!(args)
    }

    response = complete_response!(run, [call])
    run = %{run | model_response: response, calls: [call], round_calls: [call]}
    assert {:ok, tool, args} = Tools.prepare(run, call)
    result = Tools.execute(run, call, tool, args)
    assert {:ok, journal} = Run.record_round(%{run | results: %{call["call_id"] => result}})

    {%{run | anchor: journal.message.id, calls: [], round_calls: [], saw_tool_results: true},
     result}
  end

  defp fire_cron(agent_uid, overrides \\ []) do
    due = DateTime.add(@base_time, 60)

    {:ok, %{cron_schedule: schedule}} =
      create_cron_schedule(
        cron_attrs(agent_uid, Keyword.merge([schedule: every_schedule(due)], overrides)),
        now: @base_time
      )

    {:ok, %{signal: input}} =
      Repo.transact(fn _repo -> Schedule.fire_cron(schedule.id, now: due) end)

    {schedule, input, admit_input(input, due), due}
  end

  defp complete_response!(run, text) when is_binary(text),
    do:
      complete_response!(run, [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }
      ])

  defp complete_response!(run, items) do
    {:ok, response} =
      start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        metadata: %{"request_metadata" => Run.metadata(run)}
      })

    {:ok, complete} = ResponseCommit.commit_complete(response, items)
    complete
  end

  defp execute_finish(run, outcome, reply) do
    {run, result} =
      execute_tool(run, "finish_scheduled", %{"outcome" => outcome, "reply" => reply})

    assert {:ok, {_state, run}} = Run.restore(run)
    {run, result}
  end

  defp complete_turn_via_aigateway!(%{kind: :scheduled} = run, text) do
    {run, result} = execute_finish(run, "reply", text)
    refute result.is_error
    assert {:ok, %{signal: event}} = Run.finalize(run, :loop_finished)

    Ankole.Repo.get!(
      Ankole.AIGateway.Schemas.Message,
      String.replace_prefix(event.final_response_id, "resp_", "")
    )
  end

  defp complete_turn_via_aigateway!(run, text) do
    complete = complete_response!(run, text)
    assert {:ok, _} = Run.finalize(%{run | anchor: complete.id}, :loop_finished)
    complete
  end

  defp dispatch_final_reply_intent!(ai_message_id) do
    intent =
      Intent
      |> where([intent], intent.ai_message_id == ^ai_message_id)
      |> Repo.all()
      |> Enum.find(fn intent ->
        get_in(intent.payload, ["metadata", "source"]) == "ai_gateway_final_reply" and
          get_in(intent.payload, ["metadata", "delivery_target", "primary"]) != false
      end)

    case intent do
      %Intent{} = intent ->
        assert {:ok, %Intent{status: :sent}} =
                 Ankole.Conversations.Delivery.dispatch(
                   intent.agent_uid,
                   intent.binding_name,
                   intent.outbound_key,
                   delivery_adapter([:post_entry, :reply_entry, :edit_entry], fn intent ->
                     {:ok,
                      %{
                        created_provider_message_id:
                          intent.target_provider_message_id || "test-final-#{ai_message_id}",
                        raw_payload: %{"provider" => "test"}
                      }}
                   end)
                 )

        :ok

      nil ->
        flunk("expected final reply intent for ai_message_id=#{ai_message_id}")
    end
  end

  defp checkback_attrs(agent_uid, overrides) do
    Map.merge(
      %{
        "agent_uid" => agent_uid,
        "session_id" => "mock:chat:schedule",
        "binding_name" => "bot",
        "tool_call_id" => "tool-check-1",
        "idempotency_key" => "checkback-key-1",
        "schedule" => %{"after" => %{"value" => 5, "unit" => "minute"}, "timezone" => "Etc/UTC"},
        "reason" => "Incident follow-up.",
        "check" => "Check the incident.",
        "context_summary" => "The incident was pending.",
        "reply_route" => %{
          "conversation_id" => public_conversation_id("mock:chat:schedule"),
          "provider_thread_id" => "thread-schedule",
          "provider_message_id" => "msg-source"
        },
        "source_provenance" => %{"test" => true}
      },
      stringify_keys(overrides)
    )
    |> Map.put_new_lazy("source_signal_id", fn ->
      Ankole.WorkFixtures.service_source(agent_uid).id
    end)
    |> Map.put_new_lazy("source_signal_id", fn ->
      Ankole.WorkFixtures.service_source(agent_uid).id
    end)
  end

  defp cron_attrs(agent_uid, overrides) do
    Map.merge(
      %{
        "agent_uid" => agent_uid,
        "owner_session_id" => "mock:chat:schedule",
        "binding_name" => "bot",
        "name" => "daily-digest",
        "schedule" => %{
          "kind" => "every",
          "every_ms" => 86_400_000,
          "anchor_at" => DateTime.to_iso8601(DateTime.add(@base_time, 1, :day))
        },
        "payload" => %{"task" => "digest"},
        "delivery" => %{
          "targets" => [
            %{
              "binding_name" => "bot",
              "conversation_id" => public_conversation_id("mock:chat:schedule"),
              "provider_thread_id" => "thread-schedule"
            }
          ]
        },
        "idempotency_key" => "cron-key-1"
      },
      stringify_keys(overrides)
    )
  end

  defp every_schedule(anchor_at) do
    %{
      "kind" => "every",
      "every_ms" => 60_000,
      "anchor_at" => DateTime.to_iso8601(anchor_at)
    }
  end

  defp ai_message_fixture(agent_uid, session_id \\ "mock:chat:schedule") do
    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent_uid, session_id)

    Repo.insert!(%Message{
      id: Ankole.Ecto.UUIDv7.autogenerate(),
      subject_uid: agent_uid,
      conversation_id: conversation.id,
      type: :message,
      status: :complete,
      content: [],
      metadata: %{},
      inserted_at: @base_time,
      updated_at: @base_time
    })
  end

  defp binding_fixture(agent_uid, name, policy, adapter \\ "lark") do
    {:ok, binding} =
      Ankole.SignalsFixtures.raw_binding_fixture(%{
        agent_uid: agent_uid,
        name: name,
        adapter: adapter,
        config_ref: "app-config://#{name}",
        filters: %{},
        unaddressed_group_message_policy: policy,
        unmatched_sender_policy: :create_standalone
      })

    binding
  end

  defp mock_adapter_context(agent_uid, binding_name) do
    AdapterContext.new(
      agent_uid: agent_uid,
      binding_name: binding_name,
      adapter: "mock-provider",
      user_name: "Mock Bot"
    )
  end

  defp emit_entry(agent_uid, binding_name, input, opts) do
    Repo.transact(fn _repo ->
      with {:ok, result} <- Observe.emit_entry(agent_uid, binding_name, input, opts),
           do: {:ok, maybe_finalize_test_inbound_batch(result)}
    end)
  end

  defp maybe_finalize_test_inbound_batch(%{inbound_batch: %InboundBatch{} = batch} = result) do
    with {:ok, finalized_results} <-
           Ankole.SignalsFixtures.finalize_due_inbound_batch_events(now: batch.available_at),
         %Signal{} = signal <- finalized_signal(finalized_results, batch.id) do
      Map.put(result, :signal, signal)
    else
      _no_signal -> result
    end
  end

  defp maybe_finalize_test_inbound_batch(result), do: result

  defp finalized_signal(finalized_results, batch_id) do
    Enum.find_value(finalized_results, fn
      %{inbound_batch: %InboundBatch{id: ^batch_id}, signal: %Signal{} = input} -> input
      _result -> nil
    end)
  end

  defp group_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "evt-" <> Integer.to_string(System.unique_integer([:positive])),
        provider_conversation_id: "lark:chat:group-a",
        provider_message_id: "msg-source",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"},
        text: "PING",
        explicit: false,
        author: Ankole.SignalsFixtures.group_entry().author,
        provider_time: @base_time
      },
      overrides
    )
  end

  defp lifecycle_entry(overrides) do
    Map.merge(
      %{
        source_event_id: "delete-1",
        provider_conversation_id: "lark:chat:group-a",
        provider_message_id: "msg-source",
        provider_thread_id: "thread-1",
        channel: %{kind: :im_group, reply_mode: :entry, name: "Ops"}
      },
      overrides
    )
  end

  defp actor_commit_opts(opts) do
    Keyword.merge(
      [
        signal_id: Ecto.UUID.generate(),
        driver_epoch: 1
      ],
      opts
    )
  end

  defp append_runtime_signal(agent_uid, session_id, type, opts) do
    now = Keyword.fetch!(opts, :now)
    boundary_at = Keyword.get(opts, :boundary_at, now)
    source_event_id = "#{type}-#{System.unique_integer([:positive])}"

    Repo.transact(fn repo ->
      Ankole.Signals.accept_in_tx(repo, %{
        source: "control-plane://test",
        authorization: Ankole.Principals.WorkAccess.service(),
        id: source_event_id,
        type: type,
        subject: session_id,
        time: DateTime.to_iso8601(now),
        available_at: now,
        target: %{agent_uid: agent_uid, session_id: session_id},
        sender: agent_uid,
        reply_route: %{
          binding_name: "control-plane:test",
          conversation_id: nil,
          provider_thread_id: nil,
          provider_message_id: nil
        },
        data: %{
          "session" => %{
            "agent_uid" => agent_uid,
            "session_id" => session_id,
            "binding_name" => "control-plane:test"
          },
          "reset" => %{
            "kind" => "daily",
            "boundary_at" => DateTime.to_iso8601(boundary_at),
            "timezone" => "Etc/UTC",
            "local_time" => "04:30"
          }
        }
      })
    end)
  end

  defp human_cron_rule do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()

    assert {:ok, %{cron_schedule: rule}} =
             create_cron_schedule(cron_attrs(agent.uid, []),
               now: @base_time,
               created_by: %{
                 "kind" => "operator_api",
                 "principal_uid" => to_string(Ankole.ActorRef.from_principal(human))
               }
             )

    {rule, human}
  end

  defp cron_job(id) do
    Repo.one!(
      from(job in Oban.Job,
        where: job.worker == "Ankole.Schedule.Jobs.FireCron",
        where: fragment("?->>'cron_schedule_id' = ?", job.args, ^id),
        where: job.state in ["available", "scheduled", "retryable"]
      )
    )
  end

  defp create_cron_schedule(attrs, opts) do
    agent_uid = attrs["agent_uid"] || attrs[:agent_uid]
    delivery = attrs["delivery"] || attrs[:delivery] || %{}

    for target <- delivery["targets"] || [],
        {:ok, id} <- [Ecto.UUID.cast(target["conversation_id"])],
        %Ankole.Conversations.Conversation{} = conversation <- [
          Repo.get_by(Ankole.Conversations.Conversation, id: id)
        ],
        is_binary(target["binding_name"]) do
      name = target["binding_name"]

      binding =
        case Ankole.Signals.Bindings.get_binding(agent_uid, name) do
          {:ok, binding} -> binding
          _ -> binding_fixture(agent_uid, name, :ignore, "mock-provider")
        end

      assert {:ok, _} =
               Repo.transact(fn repo ->
                 Ankole.Conversations.External.observe_conversation_in_tx(
                   repo,
                   binding,
                   %{
                     provider_conversation_id: conversation.provider_conversation_id,
                     external_kind: conversation.external_kind,
                     reply_mode: conversation.reply_mode
                   },
                   @base_time
                 )
               end)
    end

    Schedule.create_cron_schedule(
      attrs,
      Keyword.put_new(opts, :created_by, %{
        "kind" => "operator_api",
        "principal_uid" =>
          to_string(%Ankole.ActorRef{
            tenant_id: Repo.tenant_id!(),
            uid: attrs["agent_uid"] || attrs[:agent_uid]
          })
      })
    )
  end

  defp public_conversation_id(provider_id, agent_uid \\ nil, binding_name \\ "bot") do
    conversation = Ankole.ExternalConversationsFixtures.external_conversation_fixture(provider_id)

    if agent_uid do
      binding =
        case Ankole.Signals.Bindings.get_binding(agent_uid, binding_name) do
          {:ok, binding} -> binding
          _ -> binding_fixture(agent_uid, binding_name, :ignore, "mock-provider")
        end

      assert {:ok, _} =
               Repo.transact(fn repo ->
                 Ankole.Conversations.External.observe_conversation_in_tx(
                   repo,
                   binding,
                   %{
                     provider_conversation_id: provider_id,
                     external_kind: conversation.external_kind,
                     reply_mode: conversation.reply_mode
                   },
                   @base_time
                 )
               end)
    end

    conversation.id
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
