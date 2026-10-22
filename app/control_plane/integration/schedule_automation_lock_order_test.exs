defmodule Ankole.ScheduleAutomationLockOrderTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.CronSchedule
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

    drive_file_fixture(agent.uid, "automation/lock-test/main.ts")

    attrs = %{
      agent_uid: agent.uid,
      owner_session_id: source.session_id,
      source_signal_id: source.id,
      source_provenance: %{"kind" => "test"},
      reply_route: %{},
      drive_prefix: "automation/lock-test",
      label: "Schedule lock order"
    }

    assert {:ok, job} = AutomationJobs.create_job(attrs)
    assert {:ok, replacement} = AutomationJobs.create_job(attrs)
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

  test "an unchanged binding update and a due fire serialize on the consumer", ctx do
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
    assert updated.automation_job_id == ctx.job.id
    assert {:ok, %{automation_job_run: run}} = Task.await(fire.task, 10_000)
    assert run.automation_job_id == ctx.job.id

    Ankole.DataCase.assert_persisted_equal(
      Repo.all(from r in Run, where: r.automation_job_id == ^ctx.job.id),
      [run]
    )

    assert DateTime.after?(Repo.reload!(ctx.cron).next_fire_at, @slot)
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
    assert event.automation_job_id == ctx.job.id
    assert event.wake_payload["payload"] == %{"version" => 2}
    assert event.wake_payload["trigger"] == "manual"

    assert_persisted_equal(
      Repo.all(from e in ScheduledEvent, where: e.cron_schedule_id == ^ctx.cron.id),
      [event]
    )

    assert Repo.all(Run) == []
    assert Repo.reload!(ctx.cron).next_fire_at == ctx.cron.next_fire_at
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

    assert event.automation_job_id == ctx.job.id
    assert event.cron_fire_slot_at == @slot
    assert event.last_fire_error == %{"reason" => ":tenant_suspended"}
    assert event.wake_payload["payload"] == %{"version" => 2}
    assert Repo.all(Run) == []
    assert DateTime.after?(Repo.reload!(ctx.cron).next_fire_at, @slot)
  end

  test "a binding switch preserves a fire committed before the rule lock", ctx do
    update =
      pause_at_first_parent_lock(fn ->
        Schedule.update_cron_schedule(
          ctx.cron.id,
          %{"automation_job_id" => ctx.replacement.id},
          now: @now
        )
      end)

    assert {:ok, %{automation_job_run: first}} =
             Schedule.fire_cron(ctx.cron.id, now: @slot)

    assert first.automation_job_id == ctx.job.id
    after_fire = Repo.get!(CronSchedule, ctx.cron.id)
    send(update.task.pid, :continue_parent_write)
    assert {:ok, updated} = Task.await(update.task, 10_000)
    assert updated.automation_job_id == ctx.replacement.id
    assert updated.next_fire_at == after_fire.next_fire_at
    assert updated.last_fire_at == after_fire.last_fire_at

    assert {:ok, %{automation_job_run: second}} =
             Schedule.fire_cron(ctx.cron.id, now: updated.next_fire_at)

    assert second.automation_job_id == ctx.replacement.id
    refute first.id == second.id
    assert_persisted_equal(Repo.all(from r in Run, order_by: r.id), [first, second])
  end

  defp pause_at_first_parent_lock(fun) do
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
              if self() == owner and metadata.query =~ "FOR UPDATE" and
                   (metadata.query =~ ~s(FROM "automation_jobs") or
                      metadata.query =~ ~s(FROM "cron_schedules")) do
                :telemetry.detach(handler)
                send(parent, {:work_parent_locked, self()})

                receive do
                  :continue_parent_write -> :ok
                after
                  10_000 -> raise "test did not release the work parent lock"
                end
              end
            end,
            nil
          )

        fun.()
      end)

    pid = operation.task.pid
    assert_receive {:work_parent_locked, ^pid}, 5_000
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
