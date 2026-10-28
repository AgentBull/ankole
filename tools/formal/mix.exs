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
    {AnkoleWeb.WorkerChannel,
     "../../app/control_plane/lib/ankole_web/channels/worker_channel.ex"},
    {Ankole.Pod.Formula, "../../app/control_plane/lib/ankole/pod/formula.ex"},
    {Ankole.Pod.Bases.Records, "../../app/control_plane/lib/ankole/pod/bases_records.ex"},
    {Ankole.AIGateway.Artifacts.ReferenceBudget,
     "../../app/control_plane/lib/ankole/ai_gateway/artifacts/reference_budget.ex"},
    {Ankole.AIGateway.ResponseItems,
     "../../app/control_plane/lib/ankole/ai_gateway/response_items.ex"},
    {Ankole.AIGateway.ToolResultJournal,
     "../../app/control_plane/lib/ankole/ai_gateway/tool_result_journal.ex"},
    {Ankole.Files.Path, "../../app/control_plane/lib/ankole/files/path.ex"},
    {Ankole.Pod.Files, "../../app/control_plane/lib/ankole/pod/files.ex"}
  ]

  # The proof build exposes existing private calculations without changing their
  # Erlang forms. Production keeps the original visibility and API.
  @proof_exports %{
    AnkoleWeb.WorkerChannel => [advance_acked: 2],
    Ankole.Pod.Bases.Records => [field_cas: 3],
    Ankole.AIGateway.ToolResultJournal => [
      reconcile_tool_result_items: 2
    ]
  }

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
            for {module, relative} <- @targets,
                Path.expand(relative, __DIR__) in stale,
                exports = @proof_exports[module],
                not is_nil(exports) do
              expose_calculations(module, exports, dest)
            end

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

  defp expose_calculations(module, exports, dest) do
    path = Path.join(dest, "#{module}.beam")

    {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(String.to_charlist(path), [:abstract_code])

    functions = for {:function, _, name, arity, _} <- forms, do: {name, arity}
    true = Enum.all?(exports, &(&1 in functions))

    exposed =
      Enum.flat_map(forms, fn
        {:attribute, line, :module, ^module} = form ->
          [form, {:attribute, line, :export, exports}]

        form ->
          [form]
      end)

    {:ok, ^module, beam, _warnings} =
      :compile.forms(exposed, [:return_errors, :return_warnings, :debug_info])

    {:ok, {^module, [abstract_code: {:raw_abstract_v1, checked}]}} =
      :beam_lib.chunks(beam, [:abstract_code])

    # Fail the build if recompilation changes any function body, including its
    # local callees. Only the export attribute may differ.
    function_forms = fn entries -> Enum.filter(entries, &match?({:function, _, _, _, _}, &1)) end
    true = function_forms.(forms) == function_forms.(checked)
    File.write!(path, beam)
    :code.purge(module)
    :code.delete(module)
    {:module, ^module} = :code.load_binary(module, String.to_charlist(path), beam)
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
