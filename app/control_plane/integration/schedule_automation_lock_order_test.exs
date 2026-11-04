defmodule Ankole.ScheduleAutomationLockOrderTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.PrincipalsFixtures

  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ecto.Adapters.SQL.Sandbox

  @now ~U[2026-10-21 01:00:00.000000Z]
  @slot DateTime.add(@now, 1, :minute)

  setup %{tenant: tenant} do
    %{principal: agent} = agent_fixture()

    source =
      Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid,
        binding_name: "schedule-lock-test",
        now: @now
      )

    job = Ankole.WorkFixtures.applet_job(agent.uid)
    replacement = Ankole.WorkFixtures.applet_job(agent.uid)
    assert job.authorization_kind == "service"

    assert {:ok, %{cron_schedule: cron}} =
             Schedule.create_cron_schedule(
               %{
                 "agent_uid" => agent.uid,
                 "owner_session_id" => source.session_id,
                 "binding_name" => source.reply_binding_name,
                 "name" => "lock-order",
                 "schedule" => %{
                   "kind" => "every",
                   "every_ms" => 60_000,
                   "anchor_at" => DateTime.to_iso8601(@slot)
                 },
                 "timezone" => "Etc/UTC",
                 "payload" => %{},
                 "delivery" => %{
                   "targets" => [
                     %{
                       "binding_name" => source.reply_binding_name,
                       "conversation_id" => source.conversation_id
                     }
                   ]
                 },
                 "idempotency_key" => "lock-order",
                 "automation_job_id" => job.id
               },
               now: @now,
               created_by: %{
                 "kind" => "operator_api",
                 "principal_uid" =>
                   to_string(%Ankole.ActorRef{tenant_id: tenant.id, uid: agent.uid})
               }
             )

    assert cron.authorization_kind == "service"

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        delete_agent_fixture_rows(agent.uid)
        cleanup_tenant!(tenant)
      end)
    end)

    %{cron: cron, job: job, replacement: replacement}
  end

  test "a due fire retries the Binding snapshot after an unchanged target update", ctx do
    update =
      pause_at_first_parent_lock(fn ->
        Schedule.update_cron_schedule(ctx.cron.id, %{"automation_job_id" => ctx.job.id},
          now: @now
        )
      end)

    fire = start_operation(fn -> Schedule.fire_cron(ctx.cron.id, now: @slot) end)
    refute update.backend_pid == fire.backend_pid
    assert_blocked_on_consumer(fire, update)
    send(update.task.pid, :continue_parent_write)

    assert {:ok, updated} = Task.await(update.task, 10_000)
    assert Ankole.Signals.source_automation_job_id(updated) == ctx.job.id
    assert {:error, :binding_changed} = Task.await(fire.task, 10_000)
    assert Repo.all(Run) == []
    assert Repo.all(ScheduledEvent) == []

    assert {:ok, %{automation_job_run: run}} =
             Schedule.fire_cron(ctx.cron.id, now: @slot, attempt: 2)

    assert run.automation_job_id == ctx.job.id

    Ankole.DataCase.assert_persisted_equal(
      Repo.all(from r in Run, where: r.automation_job_id == ^ctx.job.id),
      [run]
    )

    assert {:ok, current} = Schedule.get_cron_schedule(ctx.cron.id)
    assert DateTime.after?(current.next_fire_at, @slot)
  end

  test "a manual fire locks its consumer before inserting its history", ctx do
    update =
      pause_at_first_parent_lock(fn ->
        Schedule.update_cron_schedule(
          ctx.cron.id,
          %{"automation_job_id" => ctx.job.id, "payload" => %{"version" => 2}},
          now: @now
        )
      end)

    manual =
      start_operation(fn ->
        Schedule.run_cron_schedule(ctx.cron.id, now: @now, tool_call_id: "manual-lock-order")
      end)

    refute update.backend_pid == manual.backend_pid
    assert_blocked_on_consumer(manual, update)
    send(update.task.pid, :continue_parent_write)

    assert {:ok, _updated} = Task.await(update.task, 10_000)
    assert {:ok, %{status: :scheduled, scheduled_event: event}} = Task.await(manual.task, 10_000)
    assert event.status == :scheduled
    assert Ankole.Signals.source_automation_job_id(event) == ctx.job.id
    assert event.wake_payload["payload"] == %{"version" => 2}
    assert event.wake_payload["trigger"] == "manual"

    assert_persisted_equal(
      Repo.all(from e in ScheduledEvent, where: e.cron_schedule_id == ^ctx.cron.id),
      [event]
    )

    assert Repo.all(Run) == []
    assert {:ok, current} = Schedule.get_cron_schedule(ctx.cron.id)
    assert current.next_fire_at == ctx.cron.next_fire_at
  end

  test "terminal fire compensation locks its consumer before inserting failed history", ctx do
    assert {:ok, _suspended} = Ankole.Tenants.suspend(ctx.tenant)

    update =
      pause_at_first_parent_lock(fn ->
        Schedule.update_cron_schedule(
          ctx.cron.id,
          %{"automation_job_id" => ctx.job.id, "payload" => %{"version" => 2}},
          now: @now
        )
      end)

    fire =
      start_operation(fn ->
        Schedule.fire_cron(ctx.cron.id, now: @slot, attempt: 10, max_attempts: 10)
      end)

    refute update.backend_pid == fire.backend_pid
    assert_blocked_on_consumer(fire, update)
    send(update.task.pid, :continue_parent_write)

    assert {:ok, _updated} = Task.await(update.task, 10_000)
    assert {:error, :tenant_suspended} = Task.await(fire.task, 10_000)

    assert %ScheduledEvent{status: :failed} =
             event =
             Repo.one!(from e in ScheduledEvent, where: e.cron_schedule_id == ^ctx.cron.id)

    assert Ankole.Signals.source_automation_job_id(event) == ctx.job.id
    assert event.cron_fire_slot_at == @slot
    assert event.last_fire_error == %{"reason" => ":tenant_suspended"}
    assert event.wake_payload["payload"] == %{"version" => 2}
    assert Repo.all(Run) == []
    assert {:ok, current} = Schedule.get_cron_schedule(ctx.cron.id)
    assert DateTime.after?(current.next_fire_at, @slot)
  end

  test "a binding switch preserves a fire committed before the rule lock", ctx do
    update =
      pause_after_cron_read(fn ->
        Schedule.update_cron_schedule(
          ctx.cron.id,
          %{"automation_job_id" => ctx.replacement.id},
          now: @now
        )
      end)

    assert {:ok, %{automation_job_run: first}} =
             Schedule.fire_cron(ctx.cron.id, now: @slot)

    assert first.automation_job_id == ctx.job.id
    assert {:ok, after_fire} = Schedule.get_cron_schedule(ctx.cron.id)
    send(update.task.pid, :continue_parent_write)
    assert {:ok, updated} = Task.await(update.task, 10_000)
    assert Ankole.Signals.source_automation_job_id(updated) == ctx.replacement.id
    assert updated.next_fire_at == after_fire.next_fire_at
    assert updated.last_fire_at == after_fire.last_fire_at

    assert {:ok, %{automation_job_run: second}} =
             Schedule.fire_cron(ctx.cron.id, now: updated.next_fire_at)

    assert second.automation_job_id == ctx.replacement.id
    refute first.id == second.id
    assert_persisted_equal(Repo.all(from r in Run, order_by: r.id), [first, second])
  end

  test "Job deletion retries a source created while it waited for the Job lock", ctx do
    {:ok, page} = Ankole.Pod.Pages.fetch(ctx.job.page_id)
    owner = actor_fixture(page.owner_uid)

    create =
      pause_at_first_parent_lock(fn ->
        Ankole.AutomationJobs.JobSources.schedules(owner, page.id, ctx.job.id, :put, %{
          name: "concurrent",
          payload: %{},
          timezone: "Etc/UTC",
          schedule: %{
            kind: "every",
            every_ms: 60_000,
            anchor_at: DateTime.to_iso8601(DateTime.utc_now())
          }
        })
      end)

    deletion =
      start_operation(fn ->
        Ankole.AutomationJobs.delete_applet_job(owner, page.id, ctx.job.id)
      end)

    assert_blocked_on_consumer(deletion, create)
    send(create.task.pid, :continue_parent_write)
    assert {:ok, source} = Task.await(create.task, 10_000)
    assert {:error, :job_sources_changed} = Task.await(deletion.task, 10_000)
    assert {:ok, _} = Schedule.get_cron_schedule(source.id)
    assert {:ok, _} = Ankole.AutomationJobs.delete_applet_job(owner, page.id, ctx.job.id)
    assert {:error, :not_found} = Schedule.get_cron_schedule(source.id)

    refute Repo.exists?(
             from b in Ankole.Signals.Binding, where: b.config_ref == ^"schedule://#{source.id}"
           )
  end

  test "a Job-owned schedule can be edited while firing to multiple consumers without deadlock",
       ctx do
    {owner, schedule} = job_owned_fanout(ctx)

    update =
      pause_at_first_parent_lock(fn ->
        capture_operation(fn ->
          Ankole.AutomationJobs.JobSources.schedules(
            owner,
            ctx.replacement.page_id,
            ctx.replacement.id,
            :put,
            %{id: schedule.id, name: "renamed fanout"}
          )
        end)
      end)

    fire =
      start_operation(fn ->
        capture_operation(fn -> Schedule.fire_cron(schedule.id, now: schedule.next_fire_at) end)
      end)

    assert_blocked_on_consumer(fire, update)
    send(update.task.pid, :continue_parent_write)

    assert {:ok, %{name: "renamed fanout"}} = Task.await(update.task, 10_000)
    assert {:ok, %{deliveries: deliveries}} = Task.await(fire.task, 10_000)
    assert length(deliveries) == 2
  end

  test "source history reads do not wait for the Job's execution lock", ctx do
    {owner, schedule} = job_owned_fanout(ctx)
    parent = self()

    holder =
      start_operation(fn ->
        Repo.transact_top_level(fn ->
          Ankole.AutomationJobs.lock_job_in_tx(ctx.replacement.id)
          send(parent, {:job_locked, self()})

          receive do
            :release_job -> {:ok, :released}
          after
            10_000 -> raise "test did not release Job lock"
          end
        end)
      end)

    assert_receive {:job_locked, holder_pid}, 5_000

    read =
      start_operation(fn ->
        Ankole.AutomationJobs.JobSources.schedules(
          owner,
          ctx.replacement.page_id,
          ctx.replacement.id,
          :runs,
          %{id: schedule.id}
        )
      end)

    try do
      assert {:ok, {:ok, %{events: [], deliveries: []}}} = Task.yield(read.task, 1_000)
    after
      send(holder_pid, :release_job)
      Task.await(holder.task, 5_000)
      Task.shutdown(read.task, 5_000)
    end
  end

  test "deleting a schedule's default Job preserves deliveries to its other consumers", ctx do
    actor = actor_fixture(ctx.cron.agent_uid)

    assert {:ok, _} =
             Ankole.Signals.put_event_binding(actor, %{
               config_ref: "schedule://#{ctx.cron.id}",
               automation_job_id: ctx.replacement.id
             })

    assert {:ok, _} =
             Ankole.AutomationJobs.delete_applet_job(actor, ctx.job.page_id, ctx.job.id)

    assert {:ok, %{status: :fired, automation_job_run: run}} =
             Schedule.fire_cron(ctx.cron.id, now: @slot)

    assert run.automation_job_id == ctx.replacement.id
    assert {:ok, _} = Schedule.update_cron_schedule(ctx.cron.id, %{name: "remaining consumer"})
    assert {:ok, _} = Schedule.pause_cron_schedule(ctx.cron.id)
    assert {:ok, _} = Schedule.resume_cron_schedule(ctx.cron.id)
    assert {:ok, _} = Schedule.run_cron_schedule(ctx.cron.id, idempotency_key: "remaining")

    assert {:ok, _} =
             Ankole.AutomationJobs.delete_applet_job(
               actor,
               ctx.replacement.page_id,
               ctx.replacement.id
             )

    assert {:ok, current} = Schedule.get_cron_schedule(ctx.cron.id)

    assert {:ok, %{status: :fired, deliveries: [], signals: [], automation_job_run: nil}} =
             Schedule.fire_cron(current.id, now: current.next_fire_at)
  end

  test "an Action default can deliver business input to an additional Agent subscriber", ctx do
    actor = actor_fixture(ctx.cron.agent_uid)
    Ankole.ConversationsFixtures.grant_chat(ctx.cron.agent_uid, ctx.cron.agent_uid)

    assert {:ok, _} =
             Ankole.Signals.put_event_binding(actor, %{
               config_ref: "schedule://#{ctx.cron.id}",
               agent_uid: ctx.cron.agent_uid,
               target: %{session_id: ctx.cron.owner_session_id}
             })

    assert {:ok, %{status: :fired, signals: [_], automation_job_run: run, deliveries: deliveries}} =
             Schedule.fire_cron(ctx.cron.id, now: @slot)

    assert run.automation_job_id == ctx.job.id
    assert length(deliveries) == 2
  end

  test "retargeting an Agent-owned schedule can overlap a fire to its existing consumers", ctx do
    actor = actor_fixture(ctx.cron.agent_uid)

    assert {:ok, _} =
             Ankole.Signals.put_event_binding(actor, %{
               config_ref: "schedule://#{ctx.cron.id}",
               automation_job_id: ctx.replacement.id
             })

    update =
      pause_at_first_parent_lock(fn ->
        capture_operation(fn ->
          Schedule.update_cron_schedule(ctx.cron.id, %{automation_job_id: ctx.replacement.id})
        end)
      end)

    fire =
      start_operation(fn ->
        capture_operation(fn -> Schedule.fire_cron(ctx.cron.id, now: @slot) end)
      end)

    assert_blocked_on_consumer(fire, update)
    send(update.task.pid, :continue_parent_write)
    assert {:ok, _} = Task.await(update.task, 10_000)
    assert {:error, :binding_changed} = Task.await(fire.task, 10_000)
    assert {:ok, %{status: :fired}} = Schedule.fire_cron(ctx.cron.id, now: @slot)
  end

  test "retargeting a checkback can overlap a fire to its existing consumers", ctx do
    actor = actor_fixture(ctx.cron.agent_uid)
    source = Ankole.WorkFixtures.service_source(ctx.cron.agent_uid)

    assert {:ok, %{scheduled_event: event}} =
             Schedule.create_check_back_later(
               %{
                 agent_uid: ctx.cron.agent_uid,
                 session_id: source.session_id,
                 source_signal_id: source.id,
                 tool_call_id: "retarget",
                 idempotency_key: "retarget",
                 automation_job_id: ctx.job.id,
                 schedule: %{"at" => DateTime.to_iso8601(@slot), "timezone" => "UTC"},
                 reason: "Check result",
                 check: "Check result",
                 context_summary: "Retarget a pending check"
               },
               now: @now
             )

    assert {:ok, _} =
             Ankole.Signals.put_event_binding(actor, %{
               config_ref: "scheduled-event://#{event.id}",
               automation_job_id: ctx.replacement.id
             })

    update =
      pause_at_first_parent_lock(fn ->
        capture_operation(fn ->
          Schedule.update_checkback(
            event.id,
            %{
              agent_uid: ctx.cron.agent_uid,
              session_id: source.session_id,
              source_signal_id: source.id,
              tool_call_id: "retarget-update",
              idempotency_key: "retarget-update",
              automation_job_id: ctx.replacement.id
            },
            now: @now
          )
        end)
      end)

    fire =
      start_operation(fn ->
        capture_operation(fn -> Schedule.fire_due_event(event.id, now: @slot) end)
      end)

    assert_blocked_on_consumer(fire, update)
    send(update.task.pid, :continue_parent_write)
    assert {:ok, _} = Task.await(update.task, 10_000)
    assert {:error, :binding_changed} = Task.await(fire.task, 10_000)
    assert {:ok, %{status: :fired}} = Schedule.fire_due_event(event.id, now: @slot)
  end

  test "retrying cron creation can overlap a fire after another consumer subscribes", ctx do
    attrs =
      ctx.cron
      |> Map.take([
        :agent_uid,
        :owner_session_id,
        :binding_name,
        :schedule,
        :timezone,
        :payload,
        :delivery
      ])
      |> Map.merge(%{
        name: "retry creation",
        idempotency_key: "retry creation",
        automation_job_id: ctx.replacement.id
      })

    opts = [now: @now, created_by: ctx.cron.created_by]
    assert {:ok, %{cron_schedule: source}} = Schedule.create_cron_schedule(attrs, opts)

    assert {:ok, _} =
             Ankole.Signals.put_event_binding(actor_fixture(ctx.cron.agent_uid), %{
               config_ref: "schedule://#{source.id}",
               automation_job_id: ctx.job.id
             })

    create =
      pause_at_first_parent_lock(fn ->
        capture_operation(fn -> Schedule.create_cron_schedule(attrs, opts) end)
      end)

    fire =
      start_operation(fn ->
        capture_operation(fn -> Schedule.fire_cron(source.id, now: @slot) end)
      end)

    assert_blocked_on_consumer(fire, create)
    send(create.task.pid, :continue_parent_write)

    assert {:ok, %{status: :already_exists, cron_schedule: retried}} =
             Task.await(create.task, 10_000)

    assert retried.id == source.id
    assert {:ok, %{status: :fired, deliveries: deliveries}} = Task.await(fire.task, 10_000)
    assert length(deliveries) == 2
  end

  defp job_owned_fanout(ctx) do
    {:ok, page} = Ankole.Pod.Pages.fetch(ctx.replacement.page_id)
    owner = actor_fixture(page.owner_uid)
    assert ctx.job.id < ctx.replacement.id

    assert {:ok, schedule} =
             Ankole.AutomationJobs.JobSources.schedules(
               owner,
               page.id,
               ctx.replacement.id,
               :put,
               %{
                 name: "job-owned fanout",
                 schedule: %{
                   kind: "every",
                   every_ms: 60_000,
                   anchor_at: DateTime.to_iso8601(DateTime.utc_now())
                 },
                 timezone: "Etc/UTC",
                 payload: %{}
               }
             )

    assert {:ok, _} =
             Ankole.Signals.put_event_binding(owner, %{
               config_ref: "schedule://#{schedule.id}",
               automation_job_id: ctx.job.id
             })

    {owner, schedule}
  end

  defp capture_operation(fun) do
    fun.()
  rescue
    error -> {:operation_error, error}
  end

  defp pause_at_first_parent_lock(fun) do
    pause_after_query(fun, fn query ->
      query =~ "FOR UPDATE" and
        (query =~ ~s(FROM "automation_jobs") or query =~ ~s(FROM "cron_schedules"))
    end)
  end

  defp pause_after_cron_read(fun) do
    pause_after_query(fun, fn query ->
      query =~ ~s(FROM "cron_schedules") and not (query =~ "FOR UPDATE")
    end)
  end

  defp pause_after_query(fun, pause?) do
    parent = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    operation =
      start_operation(fn ->
        owner = self()

        :ok =
          :telemetry.attach(
            handler,
            [:ankole, :repo, :query],
            fn _, _, metadata, _ ->
              if self() == owner and pause?.(metadata.query) do
                :telemetry.detach(handler)
                send(parent, {:parent_write_paused, self()})

                receive do
                  :continue_parent_write -> :ok
                after
                  10_000 -> raise "test did not resume the parent write"
                end
              end
            end,
            nil
          )

        fun.()
      end)

    pid = operation.task.pid
    assert_receive {:parent_write_paused, ^pid}, 5_000
    operation
  end

  defp start_operation(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.with_tenant(tenant_id, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.checkout(fn ->
              %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:database_task, self(), backend_pid})
              fun.()
            end)
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp assert_blocked_on_consumer(waiter, holder) do
    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               %{rows: [[blocked]]} =
                 Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                   holder.backend_pid,
                   waiter.backend_pid
                 ])

               blocked
             end)

    assert %{rows: [[query]]} =
             Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [waiter.backend_pid])

    assert query =~ ~s(FROM "automation_jobs")
  end
end
