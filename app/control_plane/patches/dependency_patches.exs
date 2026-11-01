defmodule Ankole.Mix.DependencyPatches do
  @moduledoc "Applies pinned dependency patches in every shared-dependency build tree."

  def aliases do
    [
      "deps.compile": [&prepare_deps_compile/1, "deps.compile", &finalize_deps_compile/1],
      "deps.loadpaths": [
        &compile_ash_dependencies/1,
        "deps.loadpaths",
        &write_ash_patches_stamp_after_loadpaths/1
      ]
    ]
  end

  @patches [
    {"ash", "ash-3.37.2.patch"},
    {"ash_postgres", "ash_postgres-2.15.2.patch"},
    {"ash_json_api", "ash_json_api-1.8.0.patch"},
    {"attesto", "attesto-2.7.0.patch"}
  ]

  @compile_state_key :ankole_ash_deps_compile
  @recompiling_key :ankole_recompiling_ash_patches

  defp prepare_deps_compile(args) do
    unless Process.get(@recompiling_key, false) do
      apps = patched_and_consumer_apps()
      had_compiled? = any_compiled?(apps)
      stamped? = ash_patches_stamped?()
      patched = patch_ash_dependencies(args)
      Process.put(@compile_state_key, {patched != [] or not stamped?, had_compiled?, args})
    end
  end

  defp finalize_deps_compile(_args) do
    unless Process.get(@recompiling_key, false) do
      case Process.delete(@compile_state_key) do
        {true, false, args} when args in [[], ["--skip-local-deps"]] ->
          if all_compiled?(patched_and_consumer_apps()), do: write_ash_patches_stamp()

        {true, true, _args} ->
          force_recompile_ash_dependencies()

        _ ->
          :ok
      end
    end
  end

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
  # deps.loadpaths snapshots them when existing beams predated the current stamp.
  defp compile_ash_dependencies(args) do
    unless "--no-compile" in args or "--no-deps-check" in args do
      patched = patch_ash_dependencies(args)

      if (patched != [] or not ash_patches_stamped?()) and
           any_compiled?(patched_and_consumer_apps()) do
        force_recompile_ash_dependencies()
      end
    end
  end

  defp write_ash_patches_stamp_after_loadpaths(args) do
    unless "--no-compile" in args or "--no-deps-check" in args do
      if not ash_patches_stamped?() and all_compiled?(patched_and_consumer_apps()) do
        write_ash_patches_stamp()
      end
    end
  end

  defp force_recompile_ash_dependencies do
    Process.put(@recompiling_key, true)

    try do
      Mix.Task.rerun("deps.compile", patched_and_consumer_apps() ++ ["--force"])
      Mix.Tasks.Compile.Elixir.clean()
      write_ash_patches_stamp()
    after
      Process.delete(@recompiling_key)
    end
  end

  defp patched_names, do: Enum.map(@patches, &elem(&1, 0))

  defp patched_and_consumer_apps do
    names = patched_names()

    consumers =
      for dependency <- Mix.Dep.load_and_cache(),
          depends_on_patch?(dependency, names),
          name = Atom.to_string(dependency.app),
          name not in names,
          do: name

    names ++ consumers
  end

  defp any_compiled?(apps) do
    Enum.any?(apps, &dep_compiled?/1)
  end

  defp all_compiled?(apps) do
    Enum.all?(apps, &dep_compiled?/1)
  end

  defp dep_compiled?(app) do
    Path.join([Mix.Project.build_path(), "lib", app, "ebin"]) |> File.dir?()
  end

  defp ash_patches_stamp_path, do: Path.join(Mix.Project.build_path(), ".ash_patches")

  defp ash_patches_stamped? do
    File.read(ash_patches_stamp_path()) == {:ok, ash_patches_stamp()}
  end

  defp write_ash_patches_stamp do
    stamp_path = ash_patches_stamp_path()
    File.mkdir_p!(Path.dirname(stamp_path))
    File.write!(stamp_path, ash_patches_stamp())
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
