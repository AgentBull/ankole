defmodule Mix.Tasks.ImGatewayIntegrationTest do
  @shortdoc "Run the IM gateway mock integration suite"
  @moduledoc """
  Runs the IM gateway mock integration scenarios in
  `test/integration/im_gateway/`.

  These exercise the full inbound → mailbox (coalescing, attention routing,
  edit/recall, commands) → agent → outbound pipeline against a mock channel
  adapter and a mock LLM. They are tagged `:im_gateway_integration` and excluded
  from the default `mix test` (see `test/test_helper.exs`) because they are
  slower and stateful; this task is the dedicated entry point.

      mix im_gateway_integration_test
      mix im_gateway_integration_test test/integration/im_gateway/commands_test.exs
      mix im_gateway_integration_test --seed 0 --max-failures 1

  Forces `MIX_ENV=test` (via `cli/0` in `mix.exs`), creates/migrates the test
  database, then delegates to `mix test --only im_gateway_integration`.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    unless Mix.env() == :test do
      Mix.raise(
        "im_gateway_integration_test must run in the test environment " <>
          "(use `MIX_ENV=test mix im_gateway_integration_test`)"
      )
    end

    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("test", build_test_args(args))
  end

  defp build_test_args(args) do
    base = ["--only", "im_gateway_integration"]

    # Scope to test/integration/im_gateway unless the caller named explicit
    # file/dir paths. A bare value like a `--seed` argument is not a path, so
    # check the filesystem.
    case Enum.any?(args, &File.exists?/1) do
      true -> base ++ args
      false -> base ++ ["test/integration/im_gateway"] ++ args
    end
  end
end
