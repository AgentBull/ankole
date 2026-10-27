defmodule Ankole.DependencyPatchesTest do
  use ExUnit.Case, async: false
  @moduletag timeout: 900_000
  @root Path.expand("../../..", __DIR__)
  @patches Path.join(@root, "app/control_plane/patches")

  test "the application uses the dependency patches in its edition build tree" do
    script = """
    Mix.start()
    Mix.env(:test)
    root = #{inspect(@root)}
    Mix.Project.in_project(:ankole, Path.join(root, "app/control_plane"), fn _ ->
      for task <- [:"deps.compile", :"deps.loadpaths"] do
        [callback, original] = Mix.Project.config()[:aliases][task]
        true = original == Atom.to_string(task)
        {:module, Ankole.Mix.DependencyPatches} = :erlang.fun_info(callback, :module)
      end
      true = Mix.Project.deps_path() == Path.join(root, "app/control_plane/deps")
      true = Mix.Project.build_path() == Path.join(root, "app/control_plane/_build/foss/test")
      IO.puts("application-build-wired")
    end)
    """

    assert command!(@root, "elixir", ["-e", script], [
             {"MIX_BUILD_PATH", nil},
             {"ANKOLE_EDITION", "foss"}
           ]) =~ "application-build-wired"
  end

  test "normal compilation replaces stale dependencies and their consumers in each warm build tree" do
    directory =
      Path.join(System.tmp_dir!(), "ankole-patches-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    # Mix and Rebar must use the same physical path for relative links.
    directory = File.cd!(directory, &File.cwd!/0)
    on_exit(fn -> File.rm_rf!(directory) end)

    deps = Path.join(directory, "deps")
    File.cp_r!(Path.join(@root, "app/control_plane/deps"), deps)

    # Only this temporary source copy returns to the real upstream version.
    upstream = Path.join(deps, "attesto")

    command!(
      upstream,
      "patch",
      ["-R", "-F", "0", "-p1", "-i", Path.join(@patches, "attesto-2.6.1.patch")],
      []
    )

    create_projects!(directory)

    builds = for name <- ["first", "second"], do: Path.join([directory, "_build", name, "test"])

    for build <- builds do
      File.mkdir_p!(build)

      File.cp_r!(
        Path.join(@root, "app/control_plane/_build/foss/test/lib"),
        Path.join(build, "lib")
      )

      env = build_env(build) ++ [{"PATCH_STAGE", "legacy"}]
      command!(directory, "mix", ["deps.compile", "attesto", "--force"], env)
      command!(directory, "mix", ["compile"], env)

      expression = """
      :rejected = try do
        Attesto.PrincipalKind.new("human", :opaque)
      rescue
        ArgumentError -> :rejected
      end
      false = PatchConsumer.opaque_supported?()
      false = PatchHost.opaque_supported?()
      IO.puts("upstream-consumers-rejected-opaque")
      """

      assert command!(
               directory,
               "mix",
               ["run", "--no-start", "--no-compile", "-e", expression],
               env
             ) =~
               "upstream-consumers-rejected-opaque"
    end

    for build <- builds do
      IO.puts("Verify dependency patches and consumers in warm build tree #{build}")
      env = build_env(build)
      output = command!(directory, "mix", ["compile", "--warnings-as-errors"], env)
      refute output =~ "incompatible types given to Attesto.PrincipalKind.new"

      stamp = Path.join(build, ".ash_patches")
      assert File.regular?(stamp)

      expression = """
      %{sub_prefix: :opaque} = Attesto.PrincipalKind.new("human", :opaque)
      true = PatchConsumer.opaque_supported?()
      true = PatchHost.opaque_supported?()
      IO.puts("patched-consumers-loaded")
      """

      assert command!(
               directory,
               "mix",
               ["run", "--no-start", "--no-compile", "-e", expression],
               env
             ) =~
               "patched-consumers-loaded"

      beams =
        for {app, module} <- [
              {"attesto", "Attesto.PrincipalKind"},
              {"patch_consumer", "PatchConsumer"},
              {"patch_host", "PatchHost"}
            ],
            do: Path.join([build, "lib", app, "ebin", "Elixir.#{module}.beam"])

      compiled = Enum.map(beams, &File.stat!(&1, time: :posix).mtime)
      current_stamp = File.read!(stamp)
      output = command!(directory, "mix", ["compile", "--warnings-as-errors"], env)
      refute output =~ "Compiling"
      assert Enum.map(beams, &File.stat!(&1, time: :posix).mtime) == compiled
      assert File.read!(stamp) == current_stamp
    end
  end

  defp create_projects!(directory) do
    File.cp!(Path.join(@root, "app/control_plane/mix.lock"), Path.join(directory, "mix.lock"))
    File.mkdir_p!(Path.join(directory, "config"))

    File.write!(Path.join(directory, "config/config.exs"), """
    import Config
    import_config #{inspect(Path.join(@root, "app/control_plane/config/dependencies.exs"))}
    """)

    File.write!(Path.join(directory, "mix.exs"), """
    Code.require_file(#{inspect(Path.join(@patches, "dependency_patches.exs"))})
    defmodule PatchHost.MixProject do
      use Mix.Project
      def project do
        [app: :patch_host, version: "0.1.0", deps_path: "deps",
         aliases: if(System.get_env("PATCH_STAGE") == "legacy", do: [], else: Ankole.Mix.DependencyPatches.aliases()),
         deps: [{:ash, "== 3.37.2"}, {:ash_postgres, "== 2.15.1"},
                {:ash_json_api, "== 1.8.0"}, {:attesto, "== 2.6.1"},
                {:patch_consumer, path: "consumer"}]]
      end
    end
    """)

    File.mkdir_p!(Path.join(directory, "consumer"))

    File.write!(Path.join(directory, "consumer/mix.exs"), """
    defmodule PatchConsumer.MixProject do
      use Mix.Project
      def project do
        [app: :patch_consumer, version: "0.1.0", deps: [{:attesto, "== 2.6.1"}]]
      end
    end
    """)

    for {path, module} <- [{"lib", PatchHost}, {"consumer/lib", PatchConsumer}] do
      File.mkdir_p!(Path.join(directory, path))

      File.write!(Path.join([directory, path, "snapshot.ex"]), """
      defmodule #{inspect(module)} do
        @opaque_supported (try do
          Attesto.PrincipalKind.new("human", :opaque)
          true
        rescue
          ArgumentError -> false
        end)
        def opaque_supported?, do: @opaque_supported
      end
      """)
    end
  end

  defp build_env(build) do
    [
      {"MIX_BUILD_PATH", build},
      {"MIX_ENV", "test"},
      {"PATCH_STAGE", nil},
      {"ANKOLE_EDITION", "foss"}
    ]
  end

  defp command!(directory, executable, args, env) do
    {output, status} =
      System.cmd(executable, args, cd: directory, env: env, stderr_to_stdout: true)

    assert status == 0, "#{executable} #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end
end
