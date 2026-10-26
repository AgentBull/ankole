defmodule Ankole.Mix.DependencyPatches do
  @moduledoc "Applies pinned dependency patches in every shared-dependency build tree."

  def aliases do
    [
      "deps.compile": [&patch_ash_dependencies/1, "deps.compile"],
      "deps.loadpaths": [&compile_ash_dependencies/1, "deps.loadpaths"]
    ]
  end

  @patches [
    {"ash", "ash-3.36.1.patch"},
    {"ash_postgres", "ash_postgres-2.15.1.patch"},
    {"ash_json_api", "ash_json_api-1.7.1.patch"},
    {"attesto", "attesto-2.6.1.patch"}
  ]

  # Patch before deps.compile takes its dependency snapshot. Gives the
  # dependencies that this call patched.
  defp patch_ash_dependencies(_args) do
    for {dependency_name, filename} <- @patches,
        dependency = Path.join(Mix.Project.deps_path(), dependency_name),
        File.dir?(dependency),
        apply_patch(dependency_name, dependency, filename) == :patched,
        do: dependency_name
  end

  defp apply_patch(dependency_name, dependency, filename) do
    patch = Path.expand(filename, __DIR__)
    arguments = ["-F", "0", "--force", "-p1", "-i", patch]
    options = [cd: dependency, stderr_to_stdout: true]

    case System.cmd("patch", ["--dry-run", "--reverse" | arguments], options) do
      {_output, 0} ->
        :applied

      {_output, _status} ->
        case System.cmd("patch", ["--forward" | arguments], options) do
          {_output, 0} ->
            :patched

          {output, _status} ->
            Mix.raise("Cannot apply the pinned #{dependency_name} fix:\n" <> output)
        end
    end
  end

  # A warm build can hold a dependency that was compiled before its patch or in
  # another Mix environment. Build the patched dependencies again before
  # deps.loadpaths snapshots them when the build stamp does not match.
  defp compile_ash_dependencies(args) do
    unless "--no-compile" in args or "--no-deps-check" in args do
      patched = patch_ash_dependencies(args)
      stamp_path = Path.join(Mix.Project.build_path(), ".ash_patches")
      stamp = ash_patches_stamp()

      if patched != [] or File.read(stamp_path) != {:ok, stamp} do
        names = Enum.map(@patches, &elem(&1, 0))

        consumers =
          for dependency <- Mix.Dep.load_and_cache(),
              depends_on_patch?(dependency, names),
              name = Atom.to_string(dependency.app),
              name not in names,
              do: name

        Mix.Task.rerun("deps.compile", names ++ consumers ++ ["--include-children", "--force"])

        Mix.Tasks.Compile.Elixir.clean()
        File.mkdir_p!(Path.dirname(stamp_path))
        File.write!(stamp_path, stamp)
      end
    end
  end

  defp depends_on_patch?(dependency, names) do
    Atom.to_string(dependency.app) in names or
      Enum.any?(dependency.deps, &depends_on_patch?(&1, names))
  end

  defp ash_patches_stamp do
    @patches
    |> Enum.map(&elem(&1, 1))
    |> then(&[Path.basename(__ENV__.file) | &1])
    |> Enum.map(fn filename ->
      {filename, File.read!(Path.expand(filename, __DIR__))}
    end)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
