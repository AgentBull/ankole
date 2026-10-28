defmodule Mix.Tasks.Ankole.Test do
  @moduledoc """
  Runs the control-plane test suite across parallel OS partitions.

  Compiles `:ankole` once in `:test`, then splits full-suite runs across
  isolated `MIX_TEST_PARTITION` worker processes (`ANKOLE_TEST_PARTITIONS`
  overrides the worker count). Invocations that target specific paths, `--stale`,
  `--failed`, `--only`, `--cover`, or an explicit `MIX_TEST_PARTITION` run
  directly in the current BEAM.
  """
  @shortdoc "Run control-plane tests across parallel partitions"
  @requirements ["app.config"]
  use Mix.Task

  @partitionable_switches [
    color: :boolean,
    exclude: :keep,
    include: :keep,
    max_cases: :integer,
    max_failures: :integer,
    seed: :integer,
    timeout: :integer,
    warnings_as_errors: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    partitions = configured_partitions()

    if run_in_process?(args, partitions) do
      Mix.Task.run("test", args)
    else
      run_partitioned(partitions, args)
    end
  end

  defp run_in_process?(args, partitions) do
    partitions <= 1 or
      env_present?("MIX_TEST_PARTITION") or
      not partitionable_args?(args)
  end

  defp partitionable_args?(args) do
    case OptionParser.parse(args, strict: @partitionable_switches) do
      {_opts, [], []} -> true
      _targeted_or_custom -> false
    end
  end

  defp configured_partitions do
    case System.get_env("ANKOLE_TEST_PARTITIONS") do
      value when value in [nil, ""] ->
        min(4, max(1, div(System.schedulers_online(), 2)))

      raw ->
        case Integer.parse(String.trim(raw)) do
          {count, ""} when count > 0 ->
            count

          _invalid ->
            Mix.raise("ANKOLE_TEST_PARTITIONS must be a positive integer, got: #{inspect(raw)}")
        end
    end
  end

  defp run_partitioned(partitions, args) do
    started_ms = System.monotonic_time(:millisecond)
    mix_exe = System.find_executable("mix") || "mix"
    Mix.shell().info("Running control-plane tests across #{partitions} partitions...")

    results =
      1..partitions
      |> Task.async_stream(
        fn partition -> run_partition_worker(mix_exe, partition, partitions, args) end,
        max_concurrency: partitions,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} ->
        report_partition_progress(result, partitions)
        result
      end)
      |> Enum.sort_by(& &1.partition)

    elapsed_s = Float.round((System.monotonic_time(:millisecond) - started_ms) / 1_000, 1)
    failures = Enum.filter(results, &(&1.status != 0))

    if failures == [] do
      totals = aggregate_counts(results)

      Mix.shell().info(
        "Finished #{partitions} partitions in #{elapsed_s}s " <>
          "(#{format_counts(totals)})"
      )
    else
      Enum.each(failures, fn failure ->
        Mix.shell().error("\n=== Partition #{failure.partition}/#{partitions} failed ===")
        IO.write(failure.output)
      end)

      Mix.raise("#{length(failures)} of #{partitions} test partitions failed after #{elapsed_s}s")
    end
  end

  defp run_partition_worker(mix_exe, partition, partitions, args) do
    worker_started_ms = System.monotonic_time(:millisecond)

    cmd_args =
      [
        "test",
        "--no-compile",
        "--no-deps-check",
        "--partitions",
        Integer.to_string(partitions)
      ] ++ partition_max_cases_args(args, partitions) ++ args

    {output, status} =
      System.cmd(mix_exe, cmd_args,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_TEST_PARTITION", Integer.to_string(partition)}
        ],
        stderr_to_stdout: true
      )

    elapsed_s = Float.round((System.monotonic_time(:millisecond) - worker_started_ms) / 1_000, 1)

    %{
      partition: partition,
      status: status,
      elapsed_s: elapsed_s,
      counts: parse_exunit_counts(output),
      output: output
    }
  end

  @doc false
  def partition_max_cases_args(args, partitions) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: @partitionable_switches)

    if Keyword.has_key?(opts, :max_cases) do
      []
    else
      max_cases = max(4, div(System.schedulers_online() * 2, partitions))
      ["--max-cases", Integer.to_string(max_cases)]
    end
  end

  defp report_partition_progress(result, partitions) do
    label = "[partition #{result.partition}/#{partitions}]"
    summary = format_counts(result.counts)

    if result.status == 0 do
      Mix.shell().info("#{label} passed in #{result.elapsed_s}s (#{summary})")
    else
      Mix.shell().error("#{label} FAILED in #{result.elapsed_s}s (#{summary})")
    end
  end

  @doc false
  def parse_exunit_counts(output) do
    plain = String.replace(output, ~r/\e\[[0-9;]*m/, "")

    case Regex.scan(~r/^Result:\s+(?:0\s+tests|(\d+)(?:\/(\d+))?\s+passed)/m, plain) do
      [_ | _] = results -> parse_modern_counts(results, plain)
      [] -> parse_legacy_counts(plain)
    end
  end

  defp parse_modern_counts(results, plain) do
    totals =
      Enum.reduce(results, %{passed: 0, tests: 0}, fn
        [_zero], acc ->
          acc

        [_, passed_raw], acc ->
          passed = String.to_integer(passed_raw)
          %{passed: acc.passed + passed, tests: acc.tests + passed}

        [_, passed_raw, total_raw], acc ->
          passed = String.to_integer(passed_raw)
          total = if total_raw == "", do: passed, else: String.to_integer(total_raw)
          %{passed: acc.passed + passed, tests: acc.tests + total}
      end)

    failed = sum_labeled_counts(plain, ~r/^Failed:\s+(\d+)\s+tests?/m)

    excluded =
      sum_labeled_counts(plain, ~r/^Result:.*?,\s*(\d+)\s+excluded/m) +
        sum_labeled_counts(plain, ~r/^Excluded:\s+(\d+)\s+tests?/m)

    %{
      tests: totals.tests,
      failures: max(failed, totals.tests - totals.passed),
      excluded: excluded
    }
  end

  defp parse_legacy_counts(plain) do
    matches = Regex.scan(~r/(\d+)\s+tests?,\s+(\d+)\s+failures?(?:,\s+(\d+)\s+excluded)?/, plain)

    Enum.reduce(matches, %{tests: 0, failures: 0, excluded: 0}, fn match, acc ->
      tests = match |> Enum.at(1) |> String.to_integer()
      failures = match |> Enum.at(2) |> String.to_integer()
      excluded = match |> Enum.at(3) |> parse_optional_integer()

      %{
        tests: acc.tests + tests,
        failures: acc.failures + failures,
        excluded: acc.excluded + excluded
      }
    end)
  end

  defp sum_labeled_counts(plain, regex) do
    regex
    |> Regex.scan(plain)
    |> Enum.reduce(0, fn [_, raw], acc -> acc + String.to_integer(raw) end)
  end

  defp parse_optional_integer(nil), do: 0
  defp parse_optional_integer(""), do: 0
  defp parse_optional_integer(value), do: String.to_integer(value)

  defp aggregate_counts(results) do
    Enum.reduce(results, %{tests: 0, failures: 0, excluded: 0}, fn %{counts: counts}, acc ->
      %{
        tests: acc.tests + counts.tests,
        failures: acc.failures + counts.failures,
        excluded: acc.excluded + counts.excluded
      }
    end)
  end

  defp format_counts(%{tests: tests, failures: failures, excluded: 0}),
    do: "#{tests} tests, #{failures} failures"

  defp format_counts(%{tests: tests, failures: failures, excluded: excluded}),
    do: "#{tests} tests, #{failures} failures, #{excluded} excluded"

  defp env_present?(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> true
      _unset -> false
    end
  end
end
