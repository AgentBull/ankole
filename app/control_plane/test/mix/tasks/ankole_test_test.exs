defmodule Mix.Tasks.Ankole.TestTest do
  use ExUnit.Case, async: false

  test "rejects non-positive ANKOLE_TEST_PARTITIONS values" do
    previous = System.get_env("ANKOLE_TEST_PARTITIONS")

    on_exit(fn ->
      if is_nil(previous),
        do: System.delete_env("ANKOLE_TEST_PARTITIONS"),
        else: System.put_env("ANKOLE_TEST_PARTITIONS", previous)
    end)

    for invalid <- ["0", "-2", "abc"] do
      System.put_env("ANKOLE_TEST_PARTITIONS", invalid)

      assert_raise Mix.Error, ~r/ANKOLE_TEST_PARTITIONS must be a positive integer/, fn ->
        Mix.Tasks.Ankole.Test.run(["--stale"])
      end
    end
  end

  test "parses Elixir 1.20 and legacy ExUnit summary counts" do
    assert Mix.Tasks.Ankole.Test.parse_exunit_counts("""
           Finished in 12.3 seconds (4.0s async, 8.3s sync)

           \e[32mResult: 84 passed\e[0m
           """) == %{tests: 84, failures: 0, excluded: 0}

    assert Mix.Tasks.Ankole.Test.parse_exunit_counts("""
           Finished in 448.9 seconds (43.8s async, 405.1s sync)

           Result: 1594/1599 passed, 16 excluded
           Failed: 5 tests
           """) == %{tests: 1599, failures: 5, excluded: 16}

    assert Mix.Tasks.Ankole.Test.parse_exunit_counts("""
           84 tests, 0 failures, 3 excluded
           """) == %{tests: 84, failures: 0, excluded: 3}
  end

  test "scales per-partition max_cases unless explicitly provided" do
    assert ["--max-cases", max_cases] = Mix.Tasks.Ankole.Test.partition_max_cases_args([], 4)
    assert String.to_integer(max_cases) >= 4
    assert Mix.Tasks.Ankole.Test.partition_max_cases_args(["--max-cases", "8"], 4) == []
  end
end
