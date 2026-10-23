defmodule Mix.Tasks.Ankole.CompileCycles do
  @moduledoc """
  Checks compile-connected cycles in the host and its local Mix dependencies.

  Each local dependency is checked with the compile manifest in its build
  directory of the host build (for example `_build/foss/test/lib/ankole_core`).
  A missing manifest stops the check, so an empty graph cannot pass.
  """
  @shortdoc "Check compile-connected cycles across the control-plane packages"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    check(Mix.Project.config()[:app])

    for %Mix.Dep{app: app, opts: opts} = dep <- Mix.Dep.cached(),
        Keyword.has_key?(opts, :path) do
      Mix.Dep.in_dependency(dep, fn _project -> check(app) end)
    end
  end

  defp check(app) do
    manifest = Path.join(Mix.Project.manifest_path(), "compile.elixir")

    unless File.exists?(manifest),
      do: Mix.raise("#{app}: no compile manifest at #{manifest}")

    Mix.shell().info("#{app}: compile-connected cycles")

    Mix.Task.rerun("xref", [
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
