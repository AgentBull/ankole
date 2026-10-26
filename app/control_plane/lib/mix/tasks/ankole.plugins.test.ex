defmodule Mix.Tasks.Ankole.Plugins.Test do
  @moduledoc """
  Runs Plugin client unit tests without the control-plane application or database.

  Run all clients with `mix ankole.plugins.test`, or select a Plugin directory
  name with `mix ankole.plugins.test lark_adapter`. Remaining arguments go to
  `mix test`, including test file paths and ExUnit options.

  This task uses compile-time configuration and starts the HTTP client and
  time zone dependencies. Each Plugin test helper starts its client supervisor.
  Host runtime configuration and the host test helper are not loaded.
  """
  @shortdoc "Run Plugin client unit tests without a database"
  use Mix.Task

  @impl true
  def run(args) do
    assert_unit_boundary!()
    Mix.Task.run("compile")
    {:ok, _applications} = Application.ensure_all_started(:req)
    {:ok, _applications} = Application.ensure_all_started(:tzdata)

    project = Mix.Project.config()
    {test_paths, args} = select_plugin(plugin_test_paths(project), args)

    if test_paths == [], do: Mix.raise("No Plugin client test directories are configured")

    # Mix test calls app.start even with --no-start, which loads runtime.exs.
    # These unit tests need only the compile configuration and client helpers.
    aliases = Keyword.put(project[:aliases], :"app.start", fn _args -> :ok end)
    Mix.ProjectStack.merge_config(test_paths: test_paths, aliases: aliases)

    try do
      Mix.Tasks.Test.run(["--no-start" | args])
      assert_unit_boundary!()
    after
      Mix.ProjectStack.merge_config(test_paths: project[:test_paths], aliases: project[:aliases])
      Mix.Task.reenable("app.start")
    end
  end

  defp plugin_test_paths(project) do
    roots = Enum.map(["../../plugins", "../../internals/plugins"], &Path.expand/1)

    Enum.filter(project[:test_paths], fn path ->
      source = Path.expand(path)
      Enum.any?(roots, &String.starts_with?(source, &1 <> "/"))
    end)
  end

  defp select_plugin(paths, [plugin | args] = original_args) do
    case Enum.filter(paths, &(Path.basename(Path.dirname(&1)) == plugin)) do
      [] -> {paths, original_args}
      selected -> {selected, args}
    end
  end

  defp select_plugin(paths, []), do: {paths, []}

  defp assert_unit_boundary! do
    if Process.whereis(Ankole.Supervisor) || Process.whereis(Ankole.Repo) do
      Mix.raise("Plugin client unit tests must run without Ankole.Supervisor or Ankole.Repo")
    end
  end
end
