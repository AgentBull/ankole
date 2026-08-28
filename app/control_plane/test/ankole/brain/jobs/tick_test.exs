defmodule Ankole.Brain.Jobs.TickTest do
  use Ankole.DataCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.Jobs.Dreaming
  alias Ankole.Brain.Jobs.SelfHealing
  alias Ankole.Brain.Jobs.Tick
  alias Ankole.SystemConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    on_exit(fn ->
      Registry.clear_for_test()
      Cache.clear_for_test()
    end)

    :ok
  end

  test "a delayed tick evaluates the immutable insertion minute" do
    assert {:ok, "Etc/UTC"} = SystemConfig.put_timezone("UTC")

    assert :ok =
             Tick.perform(%Oban.Job{
               attempt: 2,
               inserted_at: ~U[2026-08-27 05:00:00Z],
               scheduled_at: ~U[2026-08-27 05:01:00Z]
             })

    assert_enqueued(worker: SelfHealing)
    assert_enqueued(worker: Dreaming)
  end
end
