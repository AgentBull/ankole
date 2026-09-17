defmodule Ankole.CronFireAuthorizationMigrationTest do
  use Ankole.DataCase, async: false

  alias Ankole.Principals.{HumanAccess, WorkAccess}
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  @migration Ankole.Repo.Migrations.BackfillCronFireAuthorization
  @version 20_260_917_050_211
  @unresolved %{authorization_kind: "review_required", human_uid: nil, human_access_version: nil}

  unless Code.ensure_loaded?(@migration) do
    Code.require_file(
      Path.expand(
        "../priv/repo/migrations/#{@version}_backfill_cron_fire_authorization.exs",
        __DIR__
      )
    )
  end

  test "an existing cron fire inherits its rule's authority and admits exactly one input" do
    {schedule, event, _human} = cron_fixture()
    assert is_nil(event.source_actor_event_id)
    update!(event, @unresolved)

    assert {:error, :work_authorization_review_required} =
             Schedule.fire_due_event(event.id, now: event.due_at)

    before = Repo.get!(ScheduledEvent, event.id)
    migrate()
    repaired = Repo.get!(ScheduledEvent, event.id)
    assert repaired == struct!(before, WorkAccess.fields(schedule))
    migrate()
    assert Repo.get!(ScheduledEvent, event.id) == repaired

    assert {:ok, %{status: :fired, actor_event: input}} =
             Schedule.fire_due_event(event.id, now: event.due_at)

    assert WorkAccess.fields(input) == WorkAccess.fields(schedule)
    assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: event.due_at)

    next = Repo.get_by!(ScheduledEvent, cron_schedule_id: schedule.id, status: "scheduled")
    assert next.due_at > event.due_at
    assert WorkAccess.fields(next) == WorkAccess.fields(schedule)
  end

  test "failed fires keep their failure and are not replayed" do
    {schedule, event, _human} = cron_fixture()
    update!(event, @unresolved)

    assert {:error, :work_authorization_review_required} =
             Schedule.fire_due_event(event.id, now: event.due_at, attempt: 10, max_attempts: 10)

    failed = Repo.get!(ScheduledEvent, event.id)
    assert failed.status == "failed"
    job = Repo.get!(Oban.Job, event.oban_job_id)
    next = Repo.get_by!(ScheduledEvent, cron_schedule_id: schedule.id, status: "scheduled")

    migrate()

    assert Repo.get!(ScheduledEvent, event.id) == struct!(failed, WorkAccess.fields(schedule))
    assert Repo.get!(Oban.Job, event.oban_job_id) == job
    assert Repo.get!(ScheduledEvent, next.id) == next
    assert {:ok, %{status: :noop}} = Schedule.fire_due_event(event.id, now: event.due_at)
    assert is_nil(Repo.get!(ScheduledEvent, event.id).actor_event_id)
  end

  test "backfill retains the captured Human version and cannot renew revoked access" do
    {schedule, event, human} = cron_fixture()
    update!(event, @unresolved)
    assert {:ok, disabled} = HumanAccess.disable(human.uid, "Offboarding", nil, "disable")
    assert disabled.access_version > schedule.human_access_version

    migrate()

    assert WorkAccess.fields(Repo.get!(ScheduledEvent, event.id)) == WorkAccess.fields(schedule)
    assert {:error, :human_access_revoked} = Schedule.fire_due_event(event.id, now: event.due_at)
    assert is_nil(Repo.get!(ScheduledEvent, event.id).actor_event_id)
  end

  test "an established service rule also supplies authority to its pending fire" do
    {schedule, event, _human} = cron_fixture(:service)
    update!(event, @unresolved)
    migrate()

    assert WorkAccess.fields(Repo.get!(ScheduledEvent, event.id)) == WorkAccess.fields(schedule)
    assert {:ok, %{status: :fired}} = Schedule.fire_due_event(event.id, now: event.due_at)
  end

  test "unresolved rules, unrelated events, and established authorities stay unchanged" do
    {schedule, event, _human} = cron_fixture()
    unresolved = update!(event, @unresolved)
    update!(schedule, @unresolved)

    {_schedule, established, _human} = cron_fixture()

    {other_schedule, orphan, _human} = cron_fixture()
    orphan = update!(orphan, Map.put(@unresolved, :cron_schedule_id, nil))

    {_schedule, mismatched, _human} = cron_fixture()
    mismatched = update!(mismatched, Map.put(@unresolved, :agent_uid, other_schedule.agent_uid))

    {_schedule, checkback, _human} = cron_fixture()

    checkback =
      update!(
        checkback,
        Map.merge(@unresolved, %{kind: "check_back_later", cron_schedule_id: nil})
      )

    history =
      for status <- ["fired", "cancelled"] do
        {_schedule, terminal, _human} = cron_fixture()
        update!(terminal, Map.put(@unresolved, :status, status))
      end

    migrate()

    for unchanged <- [unresolved, established, orphan, mismatched, checkback | history] do
      assert Repo.get!(ScheduledEvent, unchanged.id) == unchanged
    end
  end

  defp migrate do
    Ecto.Migration.Runner.run(
      Repo,
      Repo.config(),
      @version,
      @migration,
      :forward,
      :up,
      :up,
      log: false
    )
  end

  defp cron_fixture(authority \\ :human) do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    now = DateTime.utc_now(:microsecond)
    uid = if authority == :human, do: human.uid, else: agent.uid

    assert {:ok, %{cron_schedule: schedule}} =
             Schedule.create_cron_schedule(
               %{
                 "agent_uid" => agent.uid,
                 "owner_session_id" => "migration-test",
                 "binding_name" => "bot",
                 "name" => "daily-report",
                 "idempotency_key" => Ecto.UUID.generate(),
                 "payload" => %{"task" => "Prepare the daily report."},
                 "delivery" => %{
                   "targets" => [%{"binding_name" => "bot", "signal_channel_id" => "test:group"}]
                 },
                 "schedule" => %{
                   "kind" => "every",
                   "every_ms" => 86_400_000,
                   "anchor_at" => DateTime.to_iso8601(DateTime.add(now, 60))
                 }
               },
               now: now,
               created_by: %{"kind" => "operator_api", "principal_uid" => uid}
             )

    event = Repo.get_by!(ScheduledEvent, cron_schedule_id: schedule.id, status: "scheduled")
    {schedule, event, human}
  end

  defp update!(record, attrs), do: record |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
