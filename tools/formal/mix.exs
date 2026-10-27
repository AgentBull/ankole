defmodule Mix.Tasks.Compile.AnkoleTargets do
  @moduledoc false
  use Mix.Task.Compiler

  @targets [
    {Ankole.Pod.Position, "../../app/control_plane/lib/ankole/pod/position.ex"},
    {Ankole.Sessions.WorkerAcquisition,
     "../../app/control_plane/lib/ankole/sessions/worker_acquisition.ex"},
    {Ankole.AgentWorkers.ProviderKind.Definition,
     "../../app/control_plane/lib/ankole/agent_workers/provider_kind/definition.ex"},
    {Ankole.AgentWorkers.ProviderKind,
     "../../app/control_plane/lib/ankole/agent_workers/provider_kind.ex"},
    {Ankole.AgentWorkers.Decision,
     "../../app/control_plane/lib/ankole/agent_workers/decision.ex"},
    {Ankole.Text, "../../app/control_plane/lib/ankole/text.ex"},
    {Ankole.Attrs, "../../app/control_plane/lib/ankole/attrs.ex"},
    {Ankole.Conversations.Delivery.InteractionState,
     "../../app/control_plane/lib/ankole/conversations/delivery/interaction_state.ex"},
    {Ankole.Conversations.Delivery.ReplyPresentation,
     "../../app/control_plane/lib/ankole/conversations/delivery/reply_presentation.ex"},
    {AnkoleWeb.PodStream, "../../app/control_plane/lib/ankole_web/pod_stream.ex"},
    {Ankole.Pod.Formula, "../../app/control_plane/lib/ankole/pod/formula.ex"},
    {Ankole.Files.Path, "../../app/control_plane/lib/ankole/files/path.ex"},
    {Ankole.Pod.Files, "../../app/control_plane/lib/ankole/pod/files.ex"}
  ]

  @impl true
  def run(args) do
    # Struct declarations and imports come from the normal Control Plane build.
    # Every verified target is compiled from its owning source below.
    dependency_paths =
      Path.wildcard(Path.expand("../../app/control_plane/_build/foss/test/lib/*/ebin", __DIR__))

    Code.prepend_paths(dependency_paths)

    if dependency_paths == [] do
      Mix.raise("Compile app/control_plane first: MIX_ENV=test mix compile")
    end

    dest = Mix.Project.compile_path()
    Code.prepend_path(dest)
    File.mkdir_p!(dest)

    stale =
      for {module, rel_path} <- @targets,
          source = Path.expand(rel_path, __DIR__),
          beam = Path.join(dest, "#{module}.beam"),
          "--force" in args or stale?(source, beam) or stale?(__ENV__.file, beam) do
        :code.purge(module)
        :code.delete(module)
        File.rm(beam)
        source
      end

    if stale == [] do
      {:noop, []}
    else
      options = Code.compiler_options(ignore_module_conflict: true)

      try do
        case Kernel.ParallelCompiler.compile_to_path(stale, dest, return_diagnostics: true) do
          {:ok, _modules, _diagnostics} ->
            {:ok, []}

          {:error, errors, _diagnostics} ->
            for {module, relative} <- @targets, Path.expand(relative, __DIR__) in stale do
              :code.purge(module)
              :code.delete(module)
              File.rm(Path.join(dest, "#{module}.beam"))
            end

            {:error, errors}
        end
      after
        Code.compiler_options(options)
      end
    end
  end

  defp stale?(source, beam) do
    case {File.stat(source), File.stat(beam)} do
      {{:ok, src_stat}, {:ok, beam_stat}} -> src_stat.mtime > beam_stat.mtime
      _ -> true
    end
  end
end

defmodule Ankole.Formal.MixProject do
  use Mix.Project

  elan_bin = Path.expand("~/.elan/bin")

  if is_nil(System.find_executable("lake")) and File.dir?(elan_bin) do
    System.put_env("PATH", "#{elan_bin}:#{System.get_env("PATH", "")}")
  end

  def project do
    [
      app: :ankole_formal,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_options: [warnings_as_errors: true, debug_info: true],
      compilers: [:ankole_targets | Mix.compilers()],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  defp deps do
    [
      {:lynx,
       git: "https://github.com/josevalim/lynx.git",
       only: :test,
       compile: "sh ../../support/compile_lynx.sh"}
    ]
  end
end
