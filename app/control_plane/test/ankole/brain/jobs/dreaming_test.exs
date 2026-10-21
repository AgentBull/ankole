defmodule Ankole.Brain.Jobs.DreamingTest do
  use Ankole.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ankole.AppConfigure
  alias Ankole.Brain.Jobs.Dreaming

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)
    :ok
  end

  test "a round without a Dreaming model warns about every skipped phase" do
    assert {:ok, true} = AppConfigure.put_global_by_key("brain.enabled", true)

    log =
      capture_log([level: :warning, metadata: [:event]], fn ->
        assert :ok = Dreaming.run(%Oban.Job{args: %{}})
      end)

    assert log =~ "event=brain.dreaming.phases_skipped"

    assert {:ok, report} = Ankole.Brain.Dreaming.run()
    assert report.grade_takes == %{status: :skipped, reason: :dreaming_model_not_configured}
  end
end
