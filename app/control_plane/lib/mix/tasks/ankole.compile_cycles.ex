defmodule Mix.Tasks.Ankole.CompileCycles do
  @moduledoc "Checks compile-connected cycles in the host and its local Mix dependencies."
  @shortdoc "Check compile-connected cycles across the control-plane packages"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    config = [
      build_path: Mix.Project.build_path(),
      build_per_environment: false,
      deps_path: Mix.Project.deps_path(),
      lockfile: Path.expand(Mix.Project.config()[:lockfile] || "mix.lock")
    ]

    projects =
      Mix.Dep.cached()
      |> Enum.filter(&Keyword.has_key?(&1.opts, :path))
      |> Enum.map(&{&1.app, Keyword.fetch!(&1.opts, :path)})

    check(Mix.Project.config()[:app])

    for {app, path} <- projects do
      Mix.Project.in_project(app, path, config, fn _project -> check(app) end)
    end
  end

  defp check(app) do
    Mix.shell().info("#{app}: compile-connected cycles")

    Mix.Task.run("xref", [
      "graph",
      "--no-compile",
      "--format",
      "cycles",
      "--label",
      "compile-connected",
      "--fail-above",
      "0"
    ])
  end
end
