defmodule Mix.Tasks.Ankole.CompileCycles do
  @moduledoc """
  Checks compile-connected cycles and static Plugin dependency directions.

  Each local dependency is checked with the compile manifest in its build
  directory of the host build.
  A missing manifest stops the check, so an empty graph cannot pass.

  Domain source cannot depend on a concrete Plugin. A Plugin cannot depend on
  another Plugin. These checks include compile, export, and runtime references
  that the Elixir compiler records. Runtime module selection uses the owning
  domain's callback contract.
  """
  @shortdoc "Check compile cycles and Plugin dependency directions"
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    check(Mix.Project.config()[:app])
    check_plugin_dependencies()

    for %Mix.Dep{app: app, opts: opts} = dep <- Mix.Dep.cached(),
        Keyword.has_key?(opts, :path) do
      Mix.Dep.in_dependency(dep, fn _project -> check(app) end)
    end
  end

  defp check_plugin_dependencies do
    output = Path.join(Mix.Project.manifest_path(), "ankole_xref.json")

    Mix.Task.rerun("xref", ["graph", "--no-compile", "--format", "json", "--output", output])

    project_root = Mix.Project.project_file() |> Path.dirname() |> Path.expand()
    repo_root = Path.expand("../..", project_root)

    violations =
      for {source, references} <- output |> File.read!() |> JSON.decode!(),
          {sink, label} <- references,
          source = source |> Path.expand(project_root) |> Path.relative_to(repo_root),
          sink = sink |> Path.expand(project_root) |> Path.relative_to(repo_root),
          forbidden?(source, sink),
          do: "#{source} -> #{sink} (#{label})"

    if violations != [] do
      Mix.raise(
        "Invalid Plugin dependency directions:\n" <> Enum.join(Enum.sort(violations), "\n")
      )
    end

    Mix.shell().info("Plugin dependency directions: OK")
  end

  defp forbidden?(source, sink) do
    case {owner(source), owner(sink)} do
      {:domain, {:plugin, _}} -> true
      {{:plugin, source_plugin}, {:plugin, sink_plugin}} -> source_plugin != sink_plugin
      _ -> false
    end
  end

  defp owner(path) do
    case Path.split(path) do
      ["app", "control_plane", "lib" | _] -> :domain
      ["internals", "control_plane", "lib" | _] -> :domain
      ["plugins", plugin, "lib" | _] -> {:plugin, {:public, plugin}}
      ["internals", "plugins", plugin, "lib" | _] -> {:plugin, {:private, plugin}}
      _ -> nil
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
