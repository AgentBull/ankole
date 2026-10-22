defmodule Ankole.LockOrderTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.LockOrder
  alias Ankole.Schedule.Schemas.CronSchedule

  test "a trigger's consumer must be locked before its cron rule" do
    LockOrder.with_transaction(fn ->
      check_row_lock(CronSchedule, Ecto.UUID.generate())

      assert_raise ArgumentError, ~r/automation_jobs.*must precede cron_schedules/, fn ->
        check_row_lock(Job, 1_000)
      end
    end)
  end

  test "consumer and cron locks can be reacquired after their dependents" do
    LockOrder.with_transaction(fn ->
      id = Ecto.UUID.generate()
      check_row_lock(Job, 1_000)
      check_row_lock(CronSchedule, id)
      LockOrder.check_query(from(row in Job, lock: "FOR UPDATE"), {:rows, "automation_jobs", :id})
      LockOrder.check_rows("automation_jobs", [1_000])
      check_row_lock(CronSchedule, id)
    end)
  end

  test "query syntax cannot change a declared lock identity" do
    id = Ecto.UUID.generate()

    LockOrder.with_transaction(fn ->
      check_row_lock(Job, 1_000)
      check_row_lock(CronSchedule, id)

      LockOrder.check_query(
        from(row in Job, where: fragment("? = ?", row.id, ^1_000), lock: "FOR UPDATE"),
        {"automation_jobs", 1_000}
      )

      assert_raise ArgumentError, ~r/explicit lock_identity/, fn ->
        LockOrder.check_query(from(row in Job, lock: "FOR UPDATE"), nil)
      end
    end)
  end

  test "a later transaction has its own lock order" do
    LockOrder.with_transaction(fn -> check_row_lock(CronSchedule, Ecto.UUID.generate()) end)
    LockOrder.with_transaction(fn -> check_row_lock(Job, 1_000) end)
  end

  defp check_row_lock(schema, id) do
    LockOrder.check_query(
      from(row in schema, where: row.id == ^id, lock: "FOR UPDATE"),
      {schema.__schema__(:source), id}
    )
  end
end
